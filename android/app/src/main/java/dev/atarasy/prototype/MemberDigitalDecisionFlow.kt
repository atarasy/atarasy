package dev.atarasy.prototype

data class MemberDecisionReview(
    val handle: MemberOperationHandle,
    val prepared: MemberPreparedDecision,
    val frozen: FrozenMemberDecision,
)
sealed interface MemberDecisionActionResult {
    data class Outcome(val value: MemberDecisionOutcome) : MemberDecisionActionResult
    data object Cancelled : MemberDecisionActionResult
    data object NoCredential : MemberDecisionActionResult
    data class Failed(val failure: MemberFailure) : MemberDecisionActionResult
}

class MemberDigitalDecisionFlow(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
    private val operations: MemberDecisionOperations,
    private val passkeys: PasskeyAuthorizer,
    private val now: () -> Long = System::currentTimeMillis,
) {
    suspend fun prepare(
        session: MemberSessionInfo,
        detail: MemberOfferDetail,
        approval: MemberApproval,
        choices: Map<String, MemberDigitalChoice>,
    ): MemberDecisionReview {
        if (sessions.activeInfo() != session) throw MemberFailure.ScopeMismatch
        val draft = MemberDigitalDraft(approval)
        approval.candidates.forEach { candidate -> draft.choose(candidate.id, choices[candidate.id] ?: MemberDigitalChoice.UNDECIDED) }
        val result = operations.prepare(PreparedMemberDecision.create(environment, session, detail, draft, now()))
        return MemberDecisionReview(result.handle, result.prepared, result.frozen)
    }

    suspend fun approve(review: MemberDecisionReview): MemberDecisionActionResult {
        return try {
            val fresh = operations.review(review.handle)
            if (fresh.operationState != "prepared" || !samePrepared(fresh, review.prepared) || review.handle.attempted || review.handle.expiresAt <= now()) throw MemberFailure.ScopeMismatch
            when (val passkey = passkeys.authenticate(fresh.publicKeyJson)) {
                is PasskeyResult.Completed -> MemberDecisionActionResult.Outcome(operations.submit(review.handle, passkey.responseJson))
                PasskeyResult.Cancelled -> MemberDecisionActionResult.Cancelled
                PasskeyResult.Unavailable -> MemberDecisionActionResult.NoCredential
                is PasskeyResult.Failed -> MemberDecisionActionResult.Failed(MemberFailure.Unavailable)
            }
        } catch (failure: MemberFailure) { MemberDecisionActionResult.Failed(failure) }
    }

    private fun samePrepared(left: MemberPreparedDecision, right: MemberPreparedDecision) =
        left.profile == right.profile && left.operationId == right.operationId && left.requestDigest == right.requestDigest &&
            left.reviewedRevision == right.reviewedRevision && left.expiresAt == right.expiresAt && left.canonical == right.canonical &&
            left.review == right.review && left.publicKey == right.publicKey && left.challenge == right.challenge && left.credentialId == right.credentialId
}
