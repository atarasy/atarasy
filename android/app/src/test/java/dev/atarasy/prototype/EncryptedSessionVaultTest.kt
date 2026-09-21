package dev.atarasy.prototype

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.nio.file.Files
import javax.crypto.spec.SecretKeySpec

class EncryptedSessionVaultTest {
    private val directory = Files.createTempDirectory("atarasy-android-vault-").toFile()
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val key = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
    private val session = StoredMemberSession(
        "amr1_" + "A".repeat(43),
        MemberSessionInfo("session", "key:household", listOf("merchant"), 1_900_000_000_000),
    )

    @After fun removeDirectory() { directory.deleteRecursively() }

    @Test fun `session round trips under authenticated installation encryption without plaintext`() {
        val vault = EncryptedFileSessionVault(directory, AesGcmEnvelopeCipher(key = { key }))
        vault.save(environment, session)
        assertEquals(session, vault.load(environment, session.info.household))
        val bytes = directory.listFiles()!!.single().readBytes()
        assertFalse(bytes.toString(Charsets.UTF_8).contains(session.token))
        assertFalse(bytes.toString(Charsets.UTF_8).contains(session.info.household))
        vault.remove(environment, session.info.household)
        assertNull(vault.load(environment, session.info.household))
    }

    @Test fun `scope swap tampering and replacement installation key fail closed`() {
        val vault = EncryptedFileSessionVault(directory, AesGcmEnvelopeCipher(key = { key }))
        vault.save(environment, session)
        val other = MemberEnvironment.create("other", "https://unit.example")
        assertNull(vault.load(other, session.info.household))
        val source = directory.listFiles()!!.single().readBytes()
        vault.save(other, session)
        directory.listFiles()!!.first { !it.readBytes().contentEquals(source) }.writeBytes(source)
        assertThrows(MemberFailure.Storage::class.java) { vault.load(other, session.info.household) }
        directory.listFiles()!!.forEach { it.delete() }
        vault.save(environment, session)
        val file = directory.listFiles()!!.single(); val bytes = file.readBytes(); bytes[bytes.lastIndex] = (bytes.last() + 1).toByte(); file.writeBytes(bytes)
        assertThrows(MemberFailure.Storage::class.java) { vault.load(environment, session.info.household) }
        vault.save(environment, session)
        val replacement = EncryptedFileSessionVault(directory, AesGcmEnvelopeCipher(key = { SecretKeySpec(ByteArray(32) { 9 }, "AES") }))
        assertThrows(MemberFailure.Storage::class.java) { replacement.load(environment, session.info.household) }
    }

    @Test fun `AES envelope binds authenticated context and detects truncation`() {
        val cipher = AesGcmEnvelopeCipher(key = { key })
        val clear = "private session".toByteArray(); val aad = "scope-a".toByteArray(); val envelope = cipher.seal(clear, aad)
        assertArrayEquals(clear, cipher.open(envelope, aad))
        assertThrows(Exception::class.java) { cipher.open(envelope, "scope-b".toByteArray()) }
        assertThrows(Exception::class.java) { cipher.open(envelope.copyOf(envelope.size - 1), aad) }
    }
}
