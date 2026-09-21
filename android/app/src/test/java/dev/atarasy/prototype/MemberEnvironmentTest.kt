package dev.atarasy.prototype

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MemberEnvironmentTest {
    @Test fun `development origin and relying party are one closed scope`() {
        assertEquals("development", MemberEnvironment.development.name)
        assertEquals("https://api-dev.vox.delivery", MemberEnvironment.development.origin)
        assertEquals("api-dev.vox.delivery", MemberEnvironment.development.relyingPartyId)
    }

    @Test fun `default HTTPS port and root path are canonicalised`() {
        assertEquals("https://unit.example", MemberEnvironment.create("test", "https://unit.example:443/").origin)
    }

    @Test fun `non HTTPS credentials paths queries and fragments are refused`() {
        listOf(
            "http://unit.example", "https://user@unit.example", "https://unit.example/path",
            "https://unit.example?q=1", "https://unit.example#fragment",
        ).forEach { origin ->
            assertThrows(origin, IllegalArgumentException::class.java) { MemberEnvironment.create("test", origin) }
        }
    }
}
