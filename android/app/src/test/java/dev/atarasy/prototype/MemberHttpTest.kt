package dev.atarasy.prototype

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import kotlinx.coroutines.runBlocking
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.CookieHandler
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

private class FakeHttpConnection(url: URL, private val code: Int, private val received: ByteArray) : HttpURLConnection(url) {
    val sent = ByteArrayOutputStream()
    var disconnected = false
    override fun connect() {}
    override fun disconnect() { disconnected = true }
    override fun usingProxy() = false
    override fun getResponseCode() = code
    override fun getInputStream() = ByteArrayInputStream(received)
    override fun getErrorStream() = if (code >= 400) ByteArrayInputStream(received) else null
    override fun getOutputStream() = sent
    override fun getHeaderField(name: String?) = when (name?.lowercase()) {
        "content-type" -> "application/json; charset=utf-8"
        "cache-control" -> "private, no-store"
        "content-length" -> received.size.toString()
        else -> null
    }
}

private class RefusingCookieHandler : CookieHandler() {
    override fun get(uri: URI?, requestHeaders: MutableMap<String, MutableList<String>>?) = emptyMap<String, List<String>>()
    override fun put(uri: URI?, responseHeaders: MutableMap<String, MutableList<String>>?) {}
}

class MemberHttpTest {
    @Test fun `query encoding preserves literal plus ampersand slash and UTF-8 identity`() {
        val environment = MemberEnvironment.create("test", "https://unit.example")
        assertEquals(
            "https://unit.example/offers?household=key%3Aa%2Bb&presenter=tea%26rice%2F%C3%A9",
            memberRequestUrl(environment, "/offers", listOf("household" to "key:a+b", "presenter" to "tea&rice/é")),
        )
    }

    @Test fun `transport sends bounded JSON without redirect cache or cookie state`() = runBlocking {
        val old = CookieHandler.getDefault(); CookieHandler.setDefault(null)
        try {
            val environment = MemberEnvironment.create("test", "https://unit.example")
            val connection = FakeHttpConnection(URL("https://unit.example/auth/logout"), 204, byteArrayOf())
            val transport = UrlConnectionMemberHttpTransport(environment, 1_000, 100) { connection }
            val body = "{}".toByteArray(); val token = "amr1_" + "A".repeat(43)
            val response = transport.send(MemberHttpRequest("/auth/logout", body = body, token = token))
            assertEquals(204, response.status); assertEquals("POST", connection.requestMethod)
            assertEquals("application/json", connection.getRequestProperty("Accept"))
            assertEquals("application/json", connection.getRequestProperty("Content-Type"))
            assertEquals("Bearer $token", connection.getRequestProperty("Authorization"))
            assertFalse(connection.instanceFollowRedirects); assertFalse(connection.useCaches)
            assertEquals("{}", connection.sent.toString(Charsets.UTF_8)); assertEquals(true, connection.disconnected)
        } finally { CookieHandler.setDefault(old) }
    }

    @Test fun `transport refuses a global cookie handler and oversized response`() = runBlocking {
        val environment = MemberEnvironment.create("test", "https://unit.example")
        val old = CookieHandler.getDefault()
        try {
            CookieHandler.setDefault(RefusingCookieHandler())
            val connection = FakeHttpConnection(URL("https://unit.example/auth/session"), 200, byteArrayOf())
            val transport = UrlConnectionMemberHttpTransport(environment, 1_000, 10) { connection }
            assertThrows(IllegalArgumentException::class.java) { runBlocking { transport.send(MemberHttpRequest("/auth/session")) } }
            CookieHandler.setDefault(null)
            val oversized = FakeHttpConnection(URL("https://unit.example/auth/session"), 200, ByteArray(11))
            val bounded = UrlConnectionMemberHttpTransport(environment, 1_000, 10) { oversized }
            assertThrows(IllegalArgumentException::class.java) { runBlocking { bounded.send(MemberHttpRequest("/auth/session")) } }
            assertEquals(true, oversized.disconnected)
        } finally { CookieHandler.setDefault(old) }
    }
}
