package dev.atarasy.prototype

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private class MemorySessionVault(var stored: StoredMemberSession? = null) : MemberSessionVault {
    var removals = 0
    override fun load(environment: MemberEnvironment, household: String) = stored
    override fun save(environment: MemberEnvironment, session: StoredMemberSession) { stored = session }
    override fun remove(environment: MemberEnvironment, household: String) { removals++; stored = null }
}

private class QueueTransport(private val environment: MemberEnvironment, var responses: MutableList<MemberHttpResponse>) : MemberHttpTransport {
    val requests = mutableListOf<MemberHttpRequest>()
    override suspend fun send(request: MemberHttpRequest): MemberHttpResponse { requests += request; return responses.removeAt(0) }
}

class MemberSessionClientTest {
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val token = "amr1_" + "A".repeat(43)
    private val info = MemberSessionInfo("session", "key:household", listOf("merchant"), 5_000)
    private fun response(path: String, body: String, status: Int = 200, contentType: String? = "application/json", cache: String? = "private, no-store") = MemberHttpResponse(
        environment.origin + path, environment.origin + path, status, contentType, cache, body.toByteArray(),
    )
    private fun sessionJson(extra: String = "") = """{"id":"session","household":"key:household","presenters":["merchant"],"expiresAt":5000$extra}"""

    @Test fun `restore verifies server authority then permits bearer reads and logout removes first`() = runBlocking {
        val vault = MemorySessionVault(StoredMemberSession(token, info))
        val transport = QueueTransport(environment, mutableListOf(
            response("/auth/session", sessionJson()), response("/offers/one", "{}"),
            response("/auth/logout", "", 204, null),
        ))
        val client = MemberSessionClient(environment, transport, vault) { 1_000 }
        assertEquals(info, client.restore(info.household))
        assertEquals(200, client.read("/offers/one").status)
        assertTrue(client.logout())
        assertNull(vault.stored)
        assertEquals(listOf("/auth/session", "/offers/one", "/auth/logout"), transport.requests.map { it.path })
        assertTrue(transport.requests.all { it.token == token })
        assertFalse(client.logout())
    }

    @Test fun `unknown fields wrong scope redirects cache and revoked authority fail closed`() = runBlocking {
        val cases = listOf(
            response("/auth/session", sessionJson(",\"extra\":true")),
            response("/auth/session", sessionJson().replace("key:household", "key:foreign")),
            response("/auth/session", sessionJson(), cache = "private"),
            response("/auth/session", sessionJson()).copy(responseUrl = "https://foreign.example/auth/session"),
            response("/auth/session", "{}", status = 401),
        )
        cases.forEach { reply ->
            val vault = MemorySessionVault(StoredMemberSession(token, info))
            val client = MemberSessionClient(environment, QueueTransport(environment, mutableListOf(reply)), vault) { 1_000 }
            assertThrows(MemberFailure::class.java) { runBlocking { client.restore(info.household) } }
            if (reply.status == 401) assertNull(vault.stored)
        }
    }

    @Test fun `expiry malformed local token and household mismatch are removed without a request`() = runBlocking {
        for (stored in listOf(
            StoredMemberSession(token, info.copy(expiresAt = 999)),
            StoredMemberSession("bad", info),
            StoredMemberSession(token, info.copy(household = "key:foreign")),
        )) {
            val vault = MemorySessionVault(stored); val transport = QueueTransport(environment, mutableListOf())
            val client = MemberSessionClient(environment, transport, vault) { 1_000 }
            assertThrows(MemberFailure.Expired::class.java) { runBlocking { client.restore(info.household) } }
            assertTrue(transport.requests.isEmpty()); assertNull(vault.stored)
        }
    }

    @Test fun `locking while restore waits fences the late private response`() = runBlocking {
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val transport = object : MemberHttpTransport {
            override suspend fun send(request: MemberHttpRequest): MemberHttpResponse { entered.complete(Unit); release.await(); return response("/auth/session", sessionJson()) }
        }
        val client = MemberSessionClient(environment, transport, MemorySessionVault(StoredMemberSession(token, info))) { 1_000 }
        val restore = async { runCatching { client.restore(info.household) }.exceptionOrNull() }
        entered.await(); client.lockLocalAccess(); release.complete(Unit)
        assertTrue(restore.await() is MemberFailure.Superseded)
        assertThrows(MemberFailure.Expired::class.java) { runBlocking { client.read("/offers/one") } }
        Unit
    }

    @Test fun `response schema keeps strings and safe integer types exact`() {
        assertThrows(MemberFailure.Malformed::class.java) { MemberSessionCodec.decodeSession("""{"id":1,"household":"h","presenters":[],"expiresAt":2}""".toByteArray()) }
        assertThrows(MemberFailure.Malformed::class.java) { MemberSessionCodec.decodeSession("""{"id":"s","household":"h","presenters":[],"expiresAt":"2"}""".toByteArray()) }
    }
}
