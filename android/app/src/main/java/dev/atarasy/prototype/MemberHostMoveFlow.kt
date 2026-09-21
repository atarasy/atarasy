package dev.atarasy.prototype

import java.util.concurrent.CancellationException

enum class MemberHostMovePhase { IDLE, SIGNING_INTO_TARGET, EXPORTING, IMPORTING, VERIFYING, READY_TO_RETIRE, RETIRING, COMPLETED, SOURCE_RETAINED, UNRESOLVED }
data class MemberHostMoveState(
    val phase: MemberHostMovePhase = MemberHostMovePhase.IDLE,
    val notice: String = "",
    val coverage: String = "",
    val receipt: MemberHostImportReceipt? = null,
)

class MemberHostMoveFlow(
    private val targetEnvironment: MemberEnvironment,
    private val sourceService: MemberHostMoveService,
    private val targetService: MemberHostMoveService,
    private val targetSessions: MemberSessionClient,
    private val sourceNode: MemberPrivateNode,
    private val targetNode: MemberPrivateNode,
    private val sourceOffers: MemberOffers,
    private val targetOffers: MemberOffers,
    private val sourceReviews: MemberReviews,
    private val targetReviews: MemberReviews,
    private val sourcePermissions: MemberPermissions,
    private val targetPermissions: MemberPermissions,
    private val passkeys: PasskeyAuthorizer,
) {
    var state = MemberHostMoveState(); private set
    private var sourceSession: MemberSessionInfo? = null
    private var exported: MemberHostExport? = null
    private var attestation: MemberHostImportAttestation? = null

    fun setSession(value: MemberSessionInfo?) {
        sourceSession = value
        if (value == null) { exported = null; attestation = null; state = MemberHostMoveState() }
    }

    suspend fun prepare(): MemberHostMoveState {
        val source = sourceSession ?: return state
        var imported = false
        try {
            state = state.copy(phase = MemberHostMovePhase.SIGNING_INTO_TARGET, notice = "Sign in to the target host. Source access remains active.", coverage = "", receipt = null)
            val login = targetSessions.loginOptions(); val target = targetSessions.finishLogin(login, authenticate(login.publicKeyJson))
            if (target.household != source.household || target.presenters.sorted() != source.presenters.sorted()) throw MemberFailure.ScopeMismatch
            state = state.copy(phase = MemberHostMovePhase.EXPORTING)
            val sourceSurface = surface(sourceOffers, sourceReviews, source)
            val originalPermissions = sourcePermissions.list()
            val archive = sourceService.export(targetEnvironment)
            val move = sourceNode.prepareMove(targetEnvironment, source)
            if (archive.privateRecords != move.source) throw MemberFailure.ScopeMismatch
            state = state.copy(phase = MemberHostMovePhase.IMPORTING)
            val receipt = targetService.import(archive, move.target); imported = true
            if (targetService.importStatus(archive.digest) != receipt) throw MemberFailure.ScopeMismatch
            if (targetNode.open(target) != MemberPrivateNodeState.RECOVERY_REQUIRED) throw MemberFailure.ScopeMismatch
            targetNode.installRecoveredKey(move.key, target)
            state = state.copy(phase = MemberHostMovePhase.VERIFYING)
            val targetSurface = surface(targetOffers, targetReviews, target)
            val movedPermissions = targetPermissions.list()
            if (sourceSurface != targetSurface || originalPermissions.household != movedPermissions.household ||
                originalPermissions.permissions != movedPermissions.permissions || movedPermissions.household != source.household) throw MemberFailure.ScopeMismatch
            val review = targetService.prepareImportAttestation(archive.digest)
            val proof = targetService.attest(review, authenticate(review.ceremony.publicKeyJson))
            exported = archive; attestation = proof
            state = MemberHostMoveState(
                MemberHostMovePhase.READY_TO_RETIRE,
                "Target verification is complete. Source access is still active until you retire it.",
                "${targetSurface.details.size} offers, ${movedPermissions.permissions.size} permissions and ${move.target.size} encrypted private records verified on ${targetEnvironment.relyingPartyId}.",
                receipt,
            )
        } catch (failure: CancellationException) {
            state = state.copy(phase = if (imported) MemberHostMovePhase.UNRESOLVED else MemberHostMovePhase.SOURCE_RETAINED, notice = "Host move stopped. Source access remains active.")
        } catch (_: Exception) {
            state = state.copy(
                phase = if (imported) MemberHostMovePhase.UNRESOLVED else MemberHostMovePhase.SOURCE_RETAINED,
                notice = if (imported) "The target may contain an imported copy, but source access remains active. Verify the target before retirement." else "Nothing was retired. Source access remains active.",
            )
        }
        return state
    }

    suspend fun retireSource(): MemberHostMoveState {
        val archive = exported ?: return state; val proof = attestation ?: return state
        if (state.phase != MemberHostMovePhase.READY_TO_RETIRE) return state
        state = state.copy(phase = MemberHostMovePhase.RETIRING)
        state = try {
            val prepared = sourceService.prepareRetirement(archive.id, proof)
            sourceService.retire(prepared, authenticate(prepared.ceremony.publicKeyJson))
            state.copy(phase = MemberHostMovePhase.COMPLETED, notice = "The target host is verified and source-host access has ended.")
        } catch (_: Exception) {
            state.copy(phase = MemberHostMovePhase.UNRESOLVED, notice = "Source retirement is unresolved. Do not repeat import. Check target receipt and source access before continuing.")
        }
        return state
    }

    suspend fun lock() {
        targetNode.lock(); targetSessions.lockLocalAccess(); setSession(null)
    }

    private suspend fun authenticate(publicKeyJson: String): String = when (val result = passkeys.authenticate(publicKeyJson)) {
        is PasskeyResult.Completed -> result.responseJson
        PasskeyResult.Cancelled -> throw CancellationException()
        PasskeyResult.Unavailable -> throw MemberFailure.Unavailable
        is PasskeyResult.Failed -> throw MemberFailure.Unavailable
    }

    private data class Surface(val summaries: List<List<MemberOfferSummary>>, val details: Map<String, MemberOfferDetail>, val settlements: Map<String, ProtocolSettlement>)
    private suspend fun surface(offers: MemberOffers, reviews: MemberReviews, session: MemberSessionInfo): Surface {
        val summaries = mutableListOf<List<MemberOfferSummary>>(); val details = sortedMapOf<String, MemberOfferDetail>(); val settlements = sortedMapOf<String, ProtocolSettlement>()
        session.presenters.sorted().forEach { presenter ->
            val rows = offers.list(presenter).sortedBy { it.id }; summaries += rows
            rows.forEach { row ->
                val detail = offers.detail(row); details[row.id] = detail
                if (row.state == "settled") {
                    val review = reviews.load(detail) as? MemberReview.Settlement ?: throw MemberFailure.ScopeMismatch
                    settlements[row.id] = review.value
                }
            }
        }
        return Surface(summaries, details, settlements)
    }
}
