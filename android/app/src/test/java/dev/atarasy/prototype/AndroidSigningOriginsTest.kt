package dev.atarasy.prototype

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidSigningOriginsTest {
    @Test fun `certificate origins are exact canonical sorted and unique`() {
        val origins = AndroidSigningOrigins.fromCertificates(listOf("certificate-b".toByteArray(), "certificate-a".toByteArray()))
        assertEquals(origins.toList().sorted(), origins.toList())
        assertTrue(origins.all { Regex("^android:apk-key-hash:[A-Za-z0-9_-]{43}$").matches(it) })
        assertThrows(IllegalArgumentException::class.java) { AndroidSigningOrigins.fromCertificates(emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { AndroidSigningOrigins.fromCertificates(listOf("same".toByteArray(), "same".toByteArray())) }
    }
}
