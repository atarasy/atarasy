package dev.atarasy.prototype

data class MemberWithdrawalReview(
    val handle: MemberOperationHandle,
    val prepared: MemberPreparedDecision,
    val frozen: FrozenMemberWithdrawal,
)

sealed interface MemberWithdrawalActionResult {
    data class Outcome(val value: MemberWithdrawalOutcome) : MemberWithdrawalActionResult
    data object Cancelled : MemberWithdrawalActionResult
    data object NoCredential : MemberWithdrawalActionResult
    data class Failed(val failure: MemberFailure) : MemberWithdrawalActionResult
}

class MemberWithdrawalFlow(
    private val sessions: MemberSessionClient,
    private val operations: MemberWithdrawalOperations,
    private val passkeys: PasskeyAuthorizer,
    private val now: () -> Long = System::currentTimeMillis,
) {
    suspend fun prepare(session: MemberSessionInfo, original: MemberOperationHandle): MemberWithdrawalReview {
        if (sessions.activeInfo() != session) throw MemberFailure.ScopeMismatch
        val result = operations.prepare(original)
        return MemberWithdrawalReview(result.handle, result.prepared, result.frozen)
    }

    suspend fun approve(review: MemberWithdrawalReview): MemberWithdrawalActionResult = try {
        val fresh = operations.review(review.handle)
        if (fresh.operationState != "prepared" || !samePrepared(fresh, review.prepared) || review.handle.attempted || review.handle.expiresAt <= now()) throw MemberFailure.ScopeMismatch
        when (val passkey = passkeys.authenticate(fresh.publicKeyJson)) {
            is PasskeyResult.Completed -> MemberWithdrawalActionResult.Outcome(operations.submit(review.handle, passkey.responseJson))
            PasskeyResult.Cancelled -> MemberWithdrawalActionResult.Cancelled
            PasskeyResult.Unavailable -> MemberWithdrawalActionResult.NoCredential
            is PasskeyResult.Failed -> MemberWithdrawalActionResult.Failed(MemberFailure.Unavailable)
        }
    } catch (failure: MemberFailure) { MemberWithdrawalActionResult.Failed(failure) }

    private fun samePrepared(left: MemberPreparedDecision, right: MemberPreparedDecision) =
        left.profile == right.profile && left.operationId == right.operationId && left.requestDigest == right.requestDigest &&
            left.reviewedRevision == right.reviewedRevision && left.expiresAt == right.expiresAt && left.canonical == right.canonical &&
            left.review == right.review && left.publicKey == right.publicKey && left.challenge == right.challenge && left.credentialId == right.credentialId
}
