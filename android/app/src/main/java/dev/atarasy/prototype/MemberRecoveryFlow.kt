package dev.atarasy.prototype

import java.util.concurrent.CancellationException

data class MemberRecoverySnapshot(
    val keyStatus: MemberRecoveryKeyStatus,
    val configuration: MemberRecoveryConfiguration,
    val requests: List<MemberRecoveryRequest>,
    val log: MemberRecoveryLog,
)

sealed interface MemberRecoveryActionResult {
    data class Completed(val notice: String) : MemberRecoveryActionResult
    data object Cancelled : MemberRecoveryActionResult
    data object NoCredential : MemberRecoveryActionResult
    data class Failed(val failure: Exception) : MemberRecoveryActionResult
}

class MemberRecoveryFlow(
    private val environment: MemberEnvironment,
    private val service: MemberRecoveryService,
    private val privateNode: MemberPrivateNode,
    private val passkeys: PasskeyAuthorizer,
    private val vault: MemberRecoveryMaterialVault,
    val noticeChannel: String?,
) {
    suspend fun refresh(): MemberRecoverySnapshot = MemberRecoverySnapshot(
        service.keyStatus(),
        service.configuration(),
        service.requests(),
        service.log(),
    )

    suspend fun registerRecoveryKey(session: MemberSessionInfo): MemberRecoveryActionResult = action {
        val pair = vault.agreementKey(scope(session.household), create = true) ?: throw MemberFailure.Storage
        val prepared = service.prepareKey(pair.publicKey)
        when (val result = passkeys.authenticate(prepared.ceremony.publicKeyJson)) {
            is PasskeyResult.Completed -> {
                service.registerKey(prepared, result.responseJson)
                MemberRecoveryActionResult.Completed("This device can now act only in a named recovery ceremony.")
            }
            PasskeyResult.Cancelled -> MemberRecoveryActionResult.Cancelled
            PasskeyResult.Unavailable -> MemberRecoveryActionResult.NoCredential
            is PasskeyResult.Failed -> MemberRecoveryActionResult.Failed(MemberFailure.Unavailable)
        }
    }

    suspend fun configure(session: MemberSessionInfo, recoverer: String): MemberRecoveryActionResult = action {
        val channel = noticeChannel?.takeIf { it.isNotBlank() }
            ?: return@action MemberRecoveryActionResult.Failed(MemberFailure.Unavailable)
        if (recoverer.isBlank() || recoverer == session.household) return@action MemberRecoveryActionResult.Failed(MemberFailure.Malformed)
        val current = service.configuration()
        val participant = service.participant(recoverer)
        val key = privateNode.recoveryKey(session)
        val shares = MemberRecoveryShares.split(key)
        val epoch = (current.epoch ?: 0) + 1
        if (epoch <= 0 || epoch > Canonical.MAXIMUM_INTEGER) throw MemberFailure.Malformed
        val device = shares.single { it.participant == MemberRecoveryParticipant.DEVICE }
        val recovererShare = shares.single { it.participant == MemberRecoveryParticipant.RECOVERER }
        val host = shares.single { it.participant == MemberRecoveryParticipant.HOST }
        val context = MemberRecoveryPacketContext("recoverer-share", session.household, recoverer, "configuration", epoch)
        val draft = MemberRecoveryConfigurationDraft(
            epoch,
            recoverer,
            MemberRecoveryShares.digest(key),
            MemberPrivateNodeCodec.b64(host.bytes),
            MemberRecoveryPackets.seal(recovererShare.bytes, participant.publicKey, context),
            channel,
        )
        val prepared = service.prepareConfiguration(draft, participant.keyDigest)
        when (val result = passkeys.authenticate(prepared.ceremony.publicKeyJson)) {
            is PasskeyResult.Completed -> {
                service.submitConfiguration(prepared, result.responseJson)
                vault.saveDeviceShare(scope(session.household), epoch, device)
                MemberRecoveryActionResult.Completed("Recovery was configured with this device, the named recoverer and the host.")
            }
            PasskeyResult.Cancelled -> MemberRecoveryActionResult.Cancelled
            PasskeyResult.Unavailable -> MemberRecoveryActionResult.NoCredential
            is PasskeyResult.Failed -> MemberRecoveryActionResult.Failed(MemberFailure.Unavailable)
        }
    }

    suspend fun beginLostDeviceRecovery(session: MemberSessionInfo): MemberRecoveryActionResult = action {
        val pair = vault.requesterKey(scope(session.household), create = true) ?: throw MemberFailure.Storage
        service.createRequest(pair.publicKey)
        MemberRecoveryActionResult.Completed("Waiting for the named recoverer and independent notice delivery.")
    }

    suspend fun approve(session: MemberSessionInfo, request: MemberRecoveryRequest): MemberRecoveryActionResult = action {
        val packet = request.recovererPacket
        if (request.recoverer != session.household || request.state != "pending" || packet == null) throw MemberFailure.ScopeMismatch
        val pair = vault.agreementKey(scope(session.household), create = false) ?: throw MemberFailure.Storage
        val inbound = MemberRecoveryPacketContext("recoverer-share", request.owner, request.recoverer, "configuration", request.epoch)
        val recovererShare = MemberRecoveryShare(MemberRecoveryParticipant.RECOVERER, MemberRecoveryPackets.open(packet, pair, inbound))
        val outbound = MemberRecoveryPacketContext("requester-release", request.owner, request.recoverer, request.id, request.epoch)
        val release = MemberRecoveryPackets.seal(recovererShare.bytes, request.requesterPublicKey, outbound)
        val prepared = service.prepareApproval(request.id, release)
        when (val result = passkeys.authenticate(prepared.ceremony.publicKeyJson)) {
            is PasskeyResult.Completed -> {
                service.approve(prepared, result.responseJson)
                MemberRecoveryActionResult.Completed("Recovery approval recorded. It grants no everyday record access.")
            }
            PasskeyResult.Cancelled -> MemberRecoveryActionResult.Cancelled
            PasskeyResult.Unavailable -> MemberRecoveryActionResult.NoCredential
            is PasskeyResult.Failed -> MemberRecoveryActionResult.Failed(MemberFailure.Unavailable)
        }
    }

    suspend fun finish(session: MemberSessionInfo, request: MemberRecoveryRequest): MemberRecoveryActionResult = action {
        if (request.owner != session.household) throw MemberFailure.ScopeMismatch
        val latest = service.request(request.id)
        val release = latest.release
        val host = latest.hostShare
        val expectedDigest = latest.keyDigest
        if (latest.state != "completed" || release == null || host == null || expectedDigest == null) throw MemberFailure.Unavailable
        val requester = vault.requesterKey(scope(session.household), create = false) ?: throw MemberFailure.Unavailable
        val context = MemberRecoveryPacketContext("requester-release", latest.owner, latest.recoverer, latest.id, latest.epoch)
        val recovererShare = MemberRecoveryShare(MemberRecoveryParticipant.RECOVERER, MemberRecoveryPackets.open(release, requester, context))
        val hostShare = MemberRecoveryShare(MemberRecoveryParticipant.HOST, MemberPrivateNodeCodec.data(host))
        val key = MemberRecoveryShares.recover(recovererShare, hostShare)
        if (MemberRecoveryShares.digest(key) != expectedDigest) throw MemberFailure.Storage
        privateNode.installRecoveredKey(key, session)
        vault.removeRequesterKey(scope(session.household))
        MemberRecoveryActionResult.Completed("Recovery completed after the independent notice was delivered.")
    }

    private fun scope(household: String) = MemberPrivateNodeCodec.scope(environment, household)

    private suspend fun action(block: suspend () -> MemberRecoveryActionResult): MemberRecoveryActionResult = try {
        block()
    } catch (failure: CancellationException) {
        throw failure
    } catch (failure: Exception) {
        MemberRecoveryActionResult.Failed(failure)
    }
}
