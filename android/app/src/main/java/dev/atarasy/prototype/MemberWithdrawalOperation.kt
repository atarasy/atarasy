package dev.atarasy.prototype

import java.nio.charset.StandardCharsets
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

const val MEMBER_WITHDRAWAL_PROFILE = "atarasy.member-withdrawal-authorisation.1"

data class FrozenMemberWithdrawal(
    val original: MemberOfferDetail,
    val approval: MemberApproval,
    val mandate: Mandate,
    val decisions: List<Decision>,
    val goods: Long,
    val carriage: Long,
    val total: Long,
    val coolingEndsAt: Long,
    val nextIncarnation: Long,
)

data class PreparedWithdrawalResult(
    val handle: MemberOperationHandle,
    val prepared: MemberPreparedDecision,
    val frozen: FrozenMemberWithdrawal,
)

sealed interface MemberWithdrawalOutcome {
    data class Recorded(val detail: MemberOfferDetail) : MemberWithdrawalOutcome
    data class Pending(val state: String) : MemberWithdrawalOutcome
    data object Unresolved : MemberWithdrawalOutcome
}

class MemberWithdrawalOperations(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
    private val store: MemberOperationStore,
    private val decisions: MemberDecisionOperations,
    private val now: () -> Long = System::currentTimeMillis,
    private val acceptedOrigins: Set<String> = setOf(environment.origin),
) {
    suspend fun prepare(originalHandle: MemberOperationHandle): PreparedWithdrawalResult {
        scope(originalHandle, MEMBER_DECISION_PROFILE)
        val active = sessions.activeInfo()
        val original = (decisions.outcome(originalHandle) as? MemberDecisionOutcome.Recorded)?.detail ?: throw MemberFailure.Unavailable
        val originalReview = decisions.review(originalHandle)
        if (originalReview.operationState != "committed") throw MemberFailure.ScopeMismatch
        val body = buildJsonObject { put("decisionOperationID", JsonPrimitive(originalHandle.id)) }.toString().toByteArray()
        val (reply, current) = sessions.readWithSession("/member/withdrawals/prepare", body = body)
        if (current != active) throw MemberFailure.Superseded
        json200(reply)
        val root = parseObject(reply.body)
        val canonical = withdrawalCanonical(root, original)
        val prepared = MemberDecisionWire.prepared(reply.body, environment, canonical, MEMBER_WITHDRAWAL_PROFILE)
        val frozen = freeze(prepared, originalHandle, original, originalReview, active)
        if (prepared.credentialId != originalHandle.credentialId) throw MemberFailure.ScopeMismatch
        val handle = MemberOperationHandle(
            prepared.operationId, MEMBER_WITHDRAWAL_PROFILE, environment.name, environment.origin, active.id, active.household,
            original.presenter, original.id, prepared.canonical, prepared.expiresAt, prepared.requestDigest, prepared.reviewedRevision,
            prepared.challenge, originalHandle.credentialId, digitalTermsDigest = MemberDigitalTerms.digest(original),
            withdrawalDecisionId = originalHandle.id, withdrawalNextIncarnation = frozen.nextIncarnation,
        )
        try { store.save(handle); return PreparedWithdrawalResult(store.load(handle.id) ?: handle, prepared, frozen) }
        catch (_: Exception) { throw MemberFailure.Storage }
    }

    suspend fun review(handle: MemberOperationHandle): MemberPreparedDecision {
        scope(handle, MEMBER_WITHDRAWAL_PROFILE)
        val (reply, _) = sessions.readWithSession("/member/operations/${handle.id}"); json200(reply)
        val value = MemberDecisionWire.prepared(reply.body, environment, handle.canonical, MEMBER_WITHDRAWAL_PROFILE)
        if (value.operationId != handle.id || value.expiresAt != handle.expiresAt || value.requestDigest != handle.requestDigest ||
            value.reviewedRevision != handle.reviewedRevision || value.challenge != handle.challenge || value.credentialId != handle.credentialId) throw MemberFailure.ScopeMismatch
        return value
    }

    suspend fun submit(handle: MemberOperationHandle, assertionJson: String): MemberWithdrawalOutcome {
        scope(handle, MEMBER_WITHDRAWAL_PROFILE)
        if (handle.expiresAt <= now() || handle.attempted || handle.digitalTermsDigest == null || handle.withdrawalDecisionId == null || handle.withdrawalNextIncarnation == null) throw MemberFailure.Expired
        val assertion = try { Json.parseToJsonElement(assertionJson).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        val id = assertion["id"]?.jsonPrimitive?.let { if (it.isString) it.content else null }
        val response = assertion["response"]?.jsonObject ?: throw MemberFailure.Malformed
        val encoded = response["clientDataJSON"]?.jsonPrimitive?.let { if (it.isString) it.content else null }
        val signature = response["signature"]?.jsonPrimitive?.let { if (it.isString) it.content else null }
        if (id != handle.credentialId || encoded == null || signature.isNullOrEmpty()) throw MemberFailure.ScopeMismatch
        val client = try { Json.parseToJsonElement(Base64.getUrlDecoder().decode(encoded).toString(StandardCharsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.ScopeMismatch }
        fun text(key: String) = client[key]?.jsonPrimitive?.let { if (it.isString) it.content else null }
        if (text("type") != "webauthn.get" || text("challenge") != handle.challenge || text("origin") !in acceptedOrigins || client.containsKey("topOrigin") ||
            (client.containsKey("crossOrigin") && client["crossOrigin"] != JsonPrimitive(false))) throw MemberFailure.ScopeMismatch
        val body = buildJsonObject { put("assertion", assertion) }.toString().toByteArray()
        if (body.size > 16_384) throw MemberFailure.Malformed
        store.claim(handle, signature)
        return try {
            val (reply, _) = sessions.readWithSession("/member/operations/${handle.id}/submit", body = body); json200(reply)
            decodeOutcome(reply.body, handle.claimed(signature))
        } catch (_: Exception) { MemberWithdrawalOutcome.Unresolved }
    }

    suspend fun outcome(handle: MemberOperationHandle): MemberWithdrawalOutcome = try {
        scope(handle, MEMBER_WITHDRAWAL_PROFILE)
        val (reply, _) = sessions.readWithSession("/member/operations/${handle.id}/outcome"); json200(reply); decodeOutcome(reply.body, handle)
    } catch (_: Exception) { MemberWithdrawalOutcome.Unresolved }

    internal fun decodeOutcome(bytes: ByteArray, handle: MemberOperationHandle): MemberWithdrawalOutcome {
        val root = parseObject(bytes)
        if (root.keys != setOf("operationID", "operationState", "withdrawal") || root.string("operationID") != handle.id) throw MemberFailure.ScopeMismatch
        val state = root.string("operationState"); val result = root.getValue("withdrawal")
        if (state != "committed") {
            if (state !in setOf("prepared", "dispatching", "uncertain", "cancelled", "refused") || result !== JsonNull) throw MemberFailure.Malformed
            return MemberWithdrawalOutcome.Pending(state)
        }
        val originalId = handle.withdrawalDecisionId ?: throw MemberFailure.ScopeMismatch
        val next = handle.withdrawalNextIncarnation ?: throw MemberFailure.ScopeMismatch
        val expectedDigest = handle.digitalTermsDigest ?: throw MemberFailure.ScopeMismatch
        val value = result.jsonObject
        if (value.keys != setOf("decisionOperationID", "nextIncarnation", "offer") || value.string("decisionOperationID") != originalId || value.number("nextIncarnation") != next) throw MemberFailure.ScopeMismatch
        val detail = rawOffer(value.getValue("offer"), handle)
        if (detail.binding != "digital" || detail.state != "presented" || detail.decidedAt != null || MemberDigitalTerms.digest(detail) != expectedDigest ||
            detail.candidates.any { it.valence != "offered" || it.decidedAt != null || it.keptAs != null || it.lineage != null }) throw MemberFailure.ScopeMismatch
        return MemberWithdrawalOutcome.Recorded(detail)
    }

    private fun freeze(
        prepared: MemberPreparedDecision,
        originalHandle: MemberOperationHandle,
        original: MemberOfferDetail,
        originalReview: MemberPreparedDecision,
        session: MemberSessionInfo,
    ): FrozenMemberWithdrawal = malformed {
        val decidedAt = original.decidedAt ?: throw MemberFailure.ScopeMismatch
        require(originalHandle.operationProfile == MEMBER_DECISION_PROFILE && original.binding == "digital" && original.state == "decided") { "scope" }
        require(prepared.operationState == "prepared" && prepared.expiresAt > now() && prepared.expiresAt <= session.expiresAt) { "scope" }
        val view = prepared.review
        require(view.keys == setOf("decisionOperationID", "incarnation", "offer", "decisionReview", "mandate", "eligibility"))
        require(view.string("decisionOperationID") == originalHandle.id) { "scope" }
        val incarnation = view.number("incarnation"); require(incarnation in 0 until Canonical.MAXIMUM_INTEGER)
        val suppliedOffer = rawOffer(view.getValue("offer"), originalHandle); require(suppliedOffer == original) { "scope" }
        val decisionReview = view.getValue("decisionReview").jsonObject
        require(decisionReview == originalReview.review) { "scope" }
        val eligibility = view.getValue("eligibility").jsonObject
        require(eligibility.keys == setOf("offer", "decidedAt", "decisionRevision", "canonical", "coolingEndsAt"))
        val revision = eligibility.string("decisionRevision"); require(Regex("^[a-f0-9]{64}$").matches(revision))
        val coolingEndsAt = eligibility.number("coolingEndsAt")
        require(eligibility.string("offer") == original.id && eligibility.number("decidedAt") == decidedAt && coolingEndsAt > now() && prepared.expiresAt <= coolingEndsAt) { "scope" }
        val canonical = listOf("valence.member-withdrawal.1", original.id, decidedAt.toString(), revision).joinToString("\n")
        require(eligibility.string("canonical") == canonical && prepared.canonical == canonical) { "scope" }
        require(originalReview.operationId == originalHandle.id && originalReview.operationState == "committed" && originalReview.requestDigest == originalHandle.requestDigest && originalReview.reviewedRevision == originalHandle.reviewedRevision) { "scope" }
        require(decisionReview.keys == setOf("approval", "mandate", "decisions", "goods", "carriage", "total"))
        val presented = original.copy(
            state = "presented", decidedAt = null,
            candidates = original.candidates.map { it.copy(valence = "offered", decidedAt = null, keptAs = null, lineage = null) },
        )
        val approval = MemberReviewCodec.approval(decisionReview.getValue("approval").toString().toByteArray(), presented)
        val draft = MemberDigitalDraft(approval)
        original.candidates.forEach { candidate ->
            require(candidate.decidedAt == decidedAt && candidate.lineage == null &&
                ((candidate.valence == "kept" && candidate.keptAs == "self") || (candidate.valence == "returned" && candidate.keptAs == null))) { "scope" }
            draft.choose(candidate.id, if (candidate.valence == "kept") MemberDigitalChoice.KEEP else MemberDigitalChoice.DECLINE)
        }
        val calculationTime = minOf(decidedAt, original.expiresAt - 1)
        val decisions = draft.decisions(calculationTime); val summary = draft.summary(calculationTime)
        require(Canonical.decisions(original.id, decisions) == originalHandle.canonical) { "scope" }
        val rows = decisionReview.getValue("decisions").jsonArray.map { it.jsonObject }
        require(rows.size == decisions.size && rows.map(::decisionTuple).toSet() == decisions.map { Triple(it.candidate, it.valence, it.keptAs) }.toSet()) { "scope" }
        require(decisionReview.number("goods") == summary.goods && decisionReview.number("carriage") == summary.carriage && decisionReview.number("total") == summary.total) { "scope" }
        require(view.getValue("mandate") == decisionReview.getValue("mandate")) { "scope" }
        val mandate = MemberDecisionWire.mandate(view.getValue("mandate"), original.mandate, original.household)
        FrozenMemberWithdrawal(original, approval, mandate, decisions, summary.goods, summary.carriage, summary.total, coolingEndsAt, incarnation + 1)
    }

    private fun withdrawalCanonical(root: JsonObject, original: MemberOfferDetail): String = malformed {
        val review = root["review"]?.jsonObject ?: throw MemberFailure.Malformed
        val eligibility = review["eligibility"]?.jsonObject ?: throw MemberFailure.Malformed
        val decidedAt = original.decidedAt ?: throw MemberFailure.ScopeMismatch
        listOf("valence.member-withdrawal.1", original.id, decidedAt.toString(), eligibility.string("decisionRevision")).joinToString("\n")
    }

    private fun rawOffer(element: JsonElement, handle: MemberOperationHandle): MemberOfferDetail = malformed {
        val objectValue = element.jsonObject.toMutableMap()
        val reminders = objectValue.remove("reminders_sent")?.jsonPrimitive?.let { require(!it.isString); it.long } ?: error("reminders")
        require(reminders in 0..1)
        MemberOfferCodec.detail(JsonObject(objectValue).toString().toByteArray(), handle.offer, handle.household, handle.presenter)
    }

    private suspend fun scope(handle: MemberOperationHandle, profile: String) {
        val active = sessions.activeInfo()
        if (handle.operationProfile != profile || handle.environment != environment.name || handle.origin != environment.origin ||
            handle.household != active.household || handle.presenter !in active.presenters) throw MemberFailure.ScopeMismatch
    }
    private fun json200(reply: MemberHttpResponse) { if (reply.status != 200) throw MemberFailure.Http(reply.status); if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed }
    private fun parseObject(bytes: ByteArray) = try { Json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun decisionTuple(row: JsonObject): Triple<String, String, String?> {
        val valence = row.string("valence")
        require(row.keys == if (valence == "kept") setOf("candidate", "valence", "kept_as") else setOf("candidate", "valence"))
        require(valence in setOf("kept", "returned"))
        val keptAs = row["kept_as"]?.jsonPrimitive?.let { require(it.isString); it.content }
        require((valence == "kept" && keptAs == "self") || (valence == "returned" && keptAs == null))
        return Triple(row.string("candidate"), valence, keptAs)
    }
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: MemberFailure.ScopeMismatch) { throw e }
    catch (e: IllegalArgumentException) { if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed }
    catch (_: Exception) { throw MemberFailure.Malformed }
}
