package dev.atarasy.prototype

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MemberOperationActionsTest {
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val session = MemberSessionInfo("session", "house", listOf("merchant"), 5_000)
    private val handle = MemberOperationHandle(
        "11111111-1111-4111-8111-111111111111", MEMBER_DECISION_PROFILE, environment.name, environment.origin, session.id,
        session.household, "merchant", "offer", "canonical", 4_000, "a".repeat(64), "b".repeat(64), "C".repeat(43), "credential",
    )

    @Test fun `only an unattempted scoped operation can be cancelled`() = runBlocking {
        fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())
        val transport = DecisionTransport(ArrayDeque(listOf(
            response("/auth/session", """{"id":"session","household":"house","presenters":["merchant"],"expiresAt":5000}"""),
            response("/member/operations/${handle.id}/cancel", """{"cancelled":true}"""),
        )))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_000 }
        sessions.restore("house"); val actions = MemberOperationActions(environment, sessions)
        actions.cancel(handle)
        assertEquals("{}", transport.requests.last().body!!.toString(Charsets.UTF_8))
        assertThrows(MemberFailure.ScopeMismatch::class.java) { runBlocking { actions.cancel(handle.copy(attempted = true, confirmationFingerprint = "f".repeat(64))) } }
        assertEquals(2, transport.requests.size)
        Unit
    }
}
