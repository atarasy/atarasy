package dev.atarasy.prototype

sealed interface MemberDialsActionResult {
    data class Recorded(val change: MemberMandateChange) : MemberDialsActionResult
    data object Cancelled : MemberDialsActionResult
    data object NoCredential : MemberDialsActionResult
    data class Failed(val failure: MemberFailure) : MemberDialsActionResult
}

class MemberDialsFlow(
    private val operations: MemberDials,
    private val passkeys: PasskeyAuthorizer,
) {
    suspend fun approve(prepared: PreparedMemberMandateChange): MemberDialsActionResult = try {
        when (val result = passkeys.authenticate(prepared.publicKeyJson)) {
            is PasskeyResult.Completed -> MemberDialsActionResult.Recorded(operations.submit(prepared, result.responseJson))
            PasskeyResult.Cancelled -> MemberDialsActionResult.Cancelled
            PasskeyResult.Unavailable -> MemberDialsActionResult.NoCredential
            is PasskeyResult.Failed -> MemberDialsActionResult.Failed(MemberFailure.Unavailable)
        }
    } catch (failure: MemberFailure) { MemberDialsActionResult.Failed(failure) }
}
