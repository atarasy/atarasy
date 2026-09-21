package dev.atarasy.prototype

data class MemberStatementReview(
    val handle: MemberOperationHandle,
    val prepared: MemberPreparedStatement,
    val local: PreparedMemberStatement,
    val detail: MemberOfferDetail,
)
sealed interface MemberStatementActionResult {
    data class Outcome(val value: MemberStatementOutcome) : MemberStatementActionResult
    data object Cancelled : MemberStatementActionResult
    data object NoCredential : MemberStatementActionResult
    data class Failed(val failure: MemberFailure) : MemberStatementActionResult
}

class MemberStatementFlow(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
    private val operations: MemberStatementOperations,
    private val passkeys: PasskeyAuthorizer,
    private val now: () -> Long = System::currentTimeMillis,
) {
    suspend fun prepare(session: MemberSessionInfo, detail: MemberOfferDetail, statement: MemberStatement, disputed: List<String>): MemberStatementReview {
        if (sessions.activeInfo() != session) throw MemberFailure.ScopeMismatch
        val local = PreparedMemberStatement.create(environment, session, detail, statement, disputed, now())
        val (handle, prepared) = operations.prepare(local, detail)
        return MemberStatementReview(handle, prepared, local, detail)
    }
    suspend fun approve(review: MemberStatementReview): MemberStatementActionResult = try {
        val fresh = operations.review(review.handle, review.local, review.detail)
        if (fresh.operationState != "prepared" || !same(fresh, review.prepared) || review.handle.attempted || review.handle.expiresAt <= now()) throw MemberFailure.ScopeMismatch
        when (val passkey = passkeys.authenticate(fresh.publicKeyJson)) {
            is PasskeyResult.Completed -> MemberStatementActionResult.Outcome(operations.submit(review.handle, passkey.responseJson))
            PasskeyResult.Cancelled -> MemberStatementActionResult.Cancelled
            PasskeyResult.Unavailable -> MemberStatementActionResult.NoCredential
            is PasskeyResult.Failed -> MemberStatementActionResult.Failed(MemberFailure.Unavailable)
        }
    } catch (failure: MemberFailure) { MemberStatementActionResult.Failed(failure) }
    private fun same(a: MemberPreparedStatement, b: MemberPreparedStatement) = a.operationId == b.operationId && a.requestDigest == b.requestDigest && a.reviewedRevision == b.reviewedRevision && a.expiresAt == b.expiresAt && a.canonical == b.canonical && a.review == b.review && a.publicKey == b.publicKey && a.challenge == b.challenge && a.credentialId == b.credentialId
}
