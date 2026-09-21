package dev.atarasy.prototype

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PasskeyRequestTest {
    @Test fun `server ceremony JSON retains every byte before Credential Manager`() {
        val json = """{ "challenge":"AA_-", "extensions":{"path":"a/b","x":true} }"""
        assertEquals(json, ServerCeremonyJson.from(json).exact)
        assertThrows(IllegalArgumentException::class.java) { ServerCeremonyJson.from("") }
        assertThrows(IllegalArgumentException::class.java) { ServerCeremonyJson.from("x".repeat(1_048_577)) }
    }
}
