package dev.atarasy.prototype

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

interface EnvelopeCipher {
    fun seal(clear: ByteArray, authenticatedData: ByteArray): ByteArray
    fun open(envelope: ByteArray, authenticatedData: ByteArray): ByteArray
}

class AesGcmEnvelopeCipher(private val key: () -> SecretKey, private val random: SecureRandom = SecureRandom()) : EnvelopeCipher {
    override fun seal(clear: ByteArray, authenticatedData: ByteArray): ByteArray {
        require(clear.size <= 1_048_576 && authenticatedData.size <= 4_096)
        val nonce = ByteArray(12).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(), GCMParameterSpec(128, nonce)); cipher.updateAAD(authenticatedData)
        val encrypted = cipher.doFinal(clear)
        return ByteBuffer.allocate(8 + nonce.size + encrypted.size).putInt(1).putInt(nonce.size).put(nonce).put(encrypted).array()
    }

    override fun open(envelope: ByteArray, authenticatedData: ByteArray): ByteArray {
        require(envelope.size in 8..1_048_640 && authenticatedData.size <= 4_096)
        val input = ByteBuffer.wrap(envelope)
        require(input.int == 1)
        val nonceSize = input.int; require(nonceSize == 12 && input.remaining() >= nonceSize + 16)
        val nonce = ByteArray(nonceSize).also(input::get)
        val encrypted = ByteArray(input.remaining()).also(input::get)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, nonce)); cipher.updateAAD(authenticatedData)
        return cipher.doFinal(encrypted)
    }
}

class AndroidInstallationCipher(alias: String = "dev.atarasy.prototype.installation.v1") : EnvelopeCipher {
    private val safeAlias = alias.also { require(Regex("^[A-Za-z0-9._-]{1,128}$").matches(it)) }
    private val delegate = AesGcmEnvelopeCipher(::installationKey)

    private fun installationKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(safeAlias, null) as? SecretKey)?.let { return it }
        val parameters = KeyGenParameterSpec.Builder(safeAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
        parameters.setUnlockedDeviceRequired(true)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run { init(parameters.build()); generateKey() }
    }

    override fun seal(clear: ByteArray, authenticatedData: ByteArray) = delegate.seal(clear, authenticatedData)
    override fun open(envelope: ByteArray, authenticatedData: ByteArray) = delegate.open(envelope, authenticatedData)
}

class EncryptedFileSessionVault(private val directory: File, private val cipher: EnvelopeCipher) : MemberSessionVault {
    init { require(directory.exists() || directory.mkdirs()) }

    override fun load(environment: MemberEnvironment, household: String): StoredMemberSession? {
        val file = file(environment, household)
        if (!file.exists()) return null
        return try {
            val value = MemberSessionCodec.decodeStored(environment, cipher.open(file.readBytes(), aad(environment, household)))
            if (value.info.household != household) throw MemberFailure.Storage
            value
        } catch (failure: MemberFailure) { throw failure } catch (_: Exception) { throw MemberFailure.Storage }
    }

    override fun save(environment: MemberEnvironment, session: StoredMemberSession) {
        val target = file(environment, session.info.household)
        val temporary = File(directory, ".${target.name}.${System.nanoTime()}.tmp")
        try {
            val envelope = cipher.seal(MemberSessionCodec.encodeStored(environment, session), aad(environment, session.info.household))
            FileOutputStream(temporary).use { it.write(envelope); it.fd.sync() }
            try { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            catch (_: Exception) { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
        } catch (failure: Exception) { temporary.delete(); if (failure is MemberFailure) throw failure else throw MemberFailure.Storage }
    }

    override fun remove(environment: MemberEnvironment, household: String) {
        val target = file(environment, household)
        if (target.exists() && !target.delete()) throw MemberFailure.Storage
    }

    private fun file(environment: MemberEnvironment, household: String): File {
        require(household.isNotEmpty())
        val digest = MessageDigest.getInstance("SHA-256").digest(aad(environment, household)).joinToString("") { "%02x".format(it) }
        return File(directory, "$digest.session")
    }
    private fun aad(environment: MemberEnvironment, household: String) = listOf("atarasy.android-session-aad.1", environment.name, environment.origin, household).joinToString("\n").toByteArray()
}
