package dev.atarasy.prototype

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MemberAndroidRefreshTest {
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val session = MemberSessionInfo("session", "key:household", emptyList(), 1_800_000_100_000)
    private fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())

    @Test fun `FCM subscription sends only the registration token and validates closed response`() = runBlocking {
        val installation = "A".repeat(22)
        val transport = DecisionTransport(ArrayDeque(listOf(
            response("/auth/session", """{"id":"session","household":"key:household","presenters":[],"expiresAt":1800000100000}"""),
            response("/member/android-refresh/subscription", """{"profile":"atarasy.member-android-refresh-subscription.1","active":true,"updatedAt":1800000000001}"""),
        )))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_000 }
        sessions.restore(session.household)
        val registered = MemberAndroidRefresh(sessions, object : MemberRefreshRegistrationProvider { override suspend fun installation() = installation }).register()
        assertTrue(registered.active); assertEquals("""{"installation":"$installation"}""", transport.requests.last().body!!.toString(Charsets.UTF_8))
    }

    @Test fun `refresh hint accepts only a data-only generic profile`() {
        assertTrue(MemberAndroidRefreshHint.valid(mapOf("profile" to MemberAndroidRefreshHint.PROFILE), false))
        assertFalse(MemberAndroidRefreshHint.valid(mapOf("profile" to MemberAndroidRefreshHint.PROFILE), true))
        assertFalse(MemberAndroidRefreshHint.valid(mapOf("profile" to MemberAndroidRefreshHint.PROFILE, "offer" to "secret"), false))
        assertFalse(MemberAndroidRefreshHint.valid(mapOf("profile" to "wrong"), false))
    }

    @Test fun `subscription rejects an active projection without update time`() = runBlocking {
        val transport = DecisionTransport(ArrayDeque(listOf(
            response("/auth/session", """{"id":"session","household":"key:household","presenters":[],"expiresAt":1800000100000}"""),
            response("/member/android-refresh", """{"profile":"atarasy.member-android-refresh-subscription.1","active":true,"updatedAt":null}"""),
        )))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_000 }; sessions.restore(session.household)
        assertThrows(MemberFailure.Malformed::class.java) { runBlocking { MemberAndroidRefresh(sessions, object : MemberRefreshRegistrationProvider { override suspend fun installation() = "A".repeat(22) }).status() } }
        Unit
    }
}
