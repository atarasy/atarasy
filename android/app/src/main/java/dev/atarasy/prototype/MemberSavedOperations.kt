package dev.atarasy.prototype

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

sealed interface MemberSavedResult {
    data class Decision(val value: MemberDecisionOutcome) : MemberSavedResult
    data class Statement(val value: MemberStatementOutcome) : MemberSavedResult
    data class Withdrawal(val value: MemberWithdrawalOutcome) : MemberSavedResult
}

class MemberSavedOperations(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
    private val store: MemberOperationStore,
    private val decisions: MemberDecisionOperations,
    private val statements: MemberStatementOperations,
    private val withdrawals: MemberWithdrawalOperations,
) {
    suspend fun list(session: MemberSessionInfo): List<MemberOperationHandle> {
        if (sessions.activeInfo() != session) throw MemberFailure.ScopeMismatch
        return try {
            withContext(Dispatchers.IO) { store.handles() }.filter { handle ->
                handle.environment == environment.name && handle.origin == environment.origin && handle.household == session.household &&
                    handle.presenter in session.presenters && handle.operationProfile in setOf(MEMBER_DECISION_PROFILE, MEMBER_STATEMENT_PROFILE, MEMBER_WITHDRAWAL_PROFILE)
            }.sortedWith(compareByDescending<MemberOperationHandle> { it.expiresAt }.thenBy { it.id })
        } catch (failure: MemberFailure) { throw failure } catch (_: Exception) { throw MemberFailure.Storage }
    }

    suspend fun check(handle: MemberOperationHandle): MemberSavedResult = when (handle.operationProfile) {
        MEMBER_DECISION_PROFILE -> MemberSavedResult.Decision(decisions.outcome(handle))
        MEMBER_STATEMENT_PROFILE -> MemberSavedResult.Statement(statements.outcome(handle))
        MEMBER_WITHDRAWAL_PROFILE -> MemberSavedResult.Withdrawal(withdrawals.outcome(handle))
        else -> throw MemberFailure.ScopeMismatch
    }
}
