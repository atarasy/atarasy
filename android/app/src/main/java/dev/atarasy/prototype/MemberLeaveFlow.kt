package dev.atarasy.prototype

import java.util.concurrent.CancellationException

enum class MemberLeavePhase { IDLE, CHECKING_STATUS, BLOCKED, READY, SIGNING, DONE, FAILED }
data class MemberLeaveState(
    val phase: MemberLeavePhase = MemberLeavePhase.IDLE,
    val notice: String = "",
    val blockers: List<MemberLeaveBlocker> = emptyList(),
    val result: MemberLeft? = null,
)

/**
 * §14.3. Loads what would block deletion, then signs and submits the deletion itself. The
 * `state` this class holds is only for its own re-entrancy checks (`deleteAccount` refuses to
 * run outside `READY`); callers read the state each action returns, the way
 * `MemberHostMoveFlow` is driven from its screen.
 */
class MemberLeaveFlow(
    private val service: MemberLeaveService,
    private val sessions: MemberSessionClient,
    private val privateNode: MemberPrivateNode,
    private val passkeys: PasskeyAuthorizer,
) {
    var state = MemberLeaveState(); private set
    private var session: MemberSessionInfo? = null

    fun setSession(value: MemberSessionInfo?) {
        session = value
        if (value == null) state = MemberLeaveState()
    }

    /** Loads what would block deletion right now. Call when the deletion screen opens, and
     * again after a blocker is resolved elsewhere. */
    suspend fun refreshStatus(): MemberLeaveState {
        if (session == null) return state
        state = state.copy(phase = MemberLeavePhase.CHECKING_STATUS, notice = "", blockers = emptyList())
        state = try {
            val status = service.status()
            if (status.blockers.isEmpty()) state.copy(phase = MemberLeavePhase.READY)
            else state.copy(phase = MemberLeavePhase.BLOCKED, blockers = status.blockers)
        } catch (_: Exception) {
            state.copy(phase = MemberLeavePhase.FAILED, notice = "Account status could not be checked. Try again.")
        }
        return state
    }

    /**
     * Prepares a fresh review, signs it with the passkey, and submits it. On success this
     * clears the saved session and local member state the way sign-out does:
     * `MemberLeaveService.submit` already removed the local session through
     * `removeRetiredLocalSession`, the same call `MemberHostMoveService.retire` makes once a
     * host move has genuinely ended access on this host, and this then locks the encrypted
     * private node and drops this flow's own session so nothing here still reads as signed in.
     *
     * No refresh teardown is issued first: the server deletes the household's push
     * subscription with the account, and switching it off before deleting would leave it off
     * if the deletion were then cancelled or refused. A blocker that appeared since the last
     * status check returns the flow to `BLOCKED` instead of failing outright.
     */
    suspend fun deleteAccount(): MemberLeaveState {
        if (session == null || state.phase != MemberLeavePhase.READY) return state
        state = state.copy(phase = MemberLeavePhase.SIGNING, notice = "")
        state = try {
            val prepared = service.prepare()
            val response = authenticate(prepared.publicKeyJson)
            val result = service.submit(prepared, response)
            privateNode.lock()
            session = null
            MemberLeaveState(
                MemberLeavePhase.DONE,
                "Your account and everything this host holds for it have been deleted. This device is now signed out.",
                emptyList(),
                result,
            )
        } catch (failure: MemberLeaveBlockedException) {
            state.copy(phase = MemberLeavePhase.BLOCKED, blockers = failure.blockers, notice = "Something is still in progress, so your account was not deleted. Finish the items below, then try again.")
        } catch (failure: CancellationException) {
            state.copy(phase = MemberLeavePhase.READY, notice = "Passkey confirmation was cancelled. Your account was not deleted.")
        } catch (_: Exception) {
            state.copy(phase = MemberLeavePhase.FAILED, notice = "The deletion result is unconfirmed. Do not repeat this request. Refresh account status before trying again.")
        }
        return state
    }

    private suspend fun authenticate(publicKeyJson: String): String = when (val result = passkeys.authenticate(publicKeyJson)) {
        is PasskeyResult.Completed -> result.responseJson
        PasskeyResult.Cancelled -> throw CancellationException()
        PasskeyResult.Unavailable -> throw MemberFailure.Unavailable
        is PasskeyResult.Failed -> throw MemberFailure.Unavailable
    }
}
