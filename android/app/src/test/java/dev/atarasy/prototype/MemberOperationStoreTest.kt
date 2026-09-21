package dev.atarasy.prototype

import java.nio.file.Files
import java.util.Base64
import javax.crypto.spec.SecretKeySpec
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MemberOperationStoreTest {
    private val directory = Files.createTempDirectory("atarasy-operations-").toFile()
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val key = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
    private val handle = MemberOperationHandle(
        "11111111-1111-4111-8111-111111111111", "atarasy.member-decision-authorisation.1", "test", environment.origin, "session",
        "key:private-household", "merchant-1", "offer-1", "offer-1\ncandidate:returned::", 1_900_000_000_000,
        "a".repeat(64), "b".repeat(64), "C".repeat(43), "credential", digitalTermsDigest = "d".repeat(64),
    )
    private fun store(secret: javax.crypto.SecretKey = key) = EncryptedFileMemberOperationStore(directory, environment, AesGcmEnvelopeCipher({ secret }))
    @After fun clean() { directory.deleteRecursively() }

    @Test fun `operation round trips encrypted and enumerates without plaintext`() {
        val store = store(); store.save(handle)
        assertEquals(handle, store.load(handle.id)); assertEquals(listOf(handle), store.handles())
        val text = directory.listFiles()!!.single().readBytes().toString(Charsets.UTF_8)
        listOf(handle.household, handle.presenter, handle.offer, handle.canonical, handle.credentialId).forEach { assertFalse(text.contains(it)) }
        assertNull(store.load("22222222-2222-4222-8222-222222222222"))
    }

    @Test fun `claim atomically persists only a signature digest and cannot repeat`() {
        val signature = Base64.getEncoder().encodeToString("assertion-signature".toByteArray())
        val store = store(); store.save(handle); store.claim(handle, signature)
        val claimed = store.load(handle.id)!!
        assertTrue(claimed.attempted); assertEquals(Canonical.digest(signature), claimed.confirmationFingerprint)
        assertThrows(MemberFailure.Busy::class.java) { store.claim(handle, Base64.getEncoder().encodeToString("another".toByteArray())) }
        assertThrows(MemberFailure.Malformed::class.java) { store.claim(handle, "not-base64") }
        assertThrows(MemberFailure.Storage::class.java) { store.save(handle.copy(canonical = "changed")) }
    }

    @Test fun `tampering context swap truncation and replacement key fail closed`() {
        val store = store(); store.save(handle); val file = directory.listFiles()!!.single(); val original = file.readBytes()
        file.writeBytes(original.copyOf(original.size - 1)); assertThrows(MemberFailure.Storage::class.java) { store.load(handle.id) }
        file.writeBytes(original); assertThrows(MemberFailure.Storage::class.java) { store(SecretKeySpec(ByteArray(32) { 9 }, "AES")).load(handle.id) }
        file.writeBytes(original); val other = EncryptedFileMemberOperationStore(directory, MemberEnvironment.create("other", environment.origin), AesGcmEnvelopeCipher({ key }))
        assertThrows(MemberFailure.Storage::class.java) { other.load(handle.id) }
    }
}
