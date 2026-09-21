package dev.atarasy.prototype

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

enum class MemberRecoveryParticipant { DEVICE, RECOVERER, HOST }
data class MemberRecoveryShare(val participant: MemberRecoveryParticipant, val bytes: ByteArray) {
    init { if (bytes.size != 64) throw MemberFailure.Malformed }
    override fun equals(other: Any?) = other is MemberRecoveryShare && participant == other.participant && bytes.contentEquals(other.bytes)
    override fun hashCode() = 31 * participant.hashCode() + bytes.contentHashCode()
}

object MemberRecoveryShares {
    private val random = SecureRandom()
    fun split(key: ByteArray): List<MemberRecoveryShare> {
        if (key.size != 32) throw MemberFailure.Malformed
        val a = ByteArray(32).also(random::nextBytes); val b = ByteArray(32).also(random::nextBytes); val c = xor(key, a, b)
        return listOf(MemberRecoveryShare(MemberRecoveryParticipant.DEVICE, a + b), MemberRecoveryShare(MemberRecoveryParticipant.RECOVERER, b + c), MemberRecoveryShare(MemberRecoveryParticipant.HOST, c + a))
    }
    fun recover(first: MemberRecoveryShare, second: MemberRecoveryShare): ByteArray {
        if (first.participant == second.participant) throw MemberFailure.Malformed
        val values = mapOf(first.participant to first.bytes, second.participant to second.bytes)
        fun head(value: ByteArray) = value.copyOfRange(0, 32)
        fun tail(value: ByteArray) = value.copyOfRange(32, 64)
        val a: ByteArray; val b: ByteArray; val c: ByteArray
        when (setOf(first.participant, second.participant)) {
            setOf(MemberRecoveryParticipant.DEVICE, MemberRecoveryParticipant.RECOVERER) -> {
                val device = values.getValue(MemberRecoveryParticipant.DEVICE); val recoverer = values.getValue(MemberRecoveryParticipant.RECOVERER)
                if (!MessageDigest.isEqual(tail(device), head(recoverer))) throw MemberFailure.Storage
                a = head(device); b = tail(device); c = tail(recoverer)
            }
            setOf(MemberRecoveryParticipant.DEVICE, MemberRecoveryParticipant.HOST) -> {
                val device = values.getValue(MemberRecoveryParticipant.DEVICE); val host = values.getValue(MemberRecoveryParticipant.HOST)
                if (!MessageDigest.isEqual(head(device), tail(host))) throw MemberFailure.Storage
                a = head(device); b = tail(device); c = head(host)
            }
            else -> {
                val recoverer = values.getValue(MemberRecoveryParticipant.RECOVERER); val host = values.getValue(MemberRecoveryParticipant.HOST)
                if (!MessageDigest.isEqual(tail(recoverer), head(host))) throw MemberFailure.Storage
                a = tail(host); b = head(recoverer); c = tail(recoverer)
            }
        }
        return xor(a, b, c)
    }
    fun digest(key: ByteArray): String { if (key.size != 32) throw MemberFailure.Malformed; return MemberPrivateNodeCodec.b64(MessageDigest.getInstance("SHA-256").digest(key)) }
    private fun xor(vararg values: ByteArray) = ByteArray(values[0].size) { index -> values.fold(0) { result, value -> result xor (value[index].toInt() and 0xff) }.toByte() }
}

data class MemberRecoveryPacketContext(val purpose: String, val owner: String, val recoverer: String, val reference: String, val epoch: Long)
data class MemberRecoveryKeyPair(val privateKeyPkcs8: ByteArray, val publicKey: String) {
    override fun equals(other: Any?) = other is MemberRecoveryKeyPair && privateKeyPkcs8.contentEquals(other.privateKeyPkcs8) && publicKey == other.publicKey
    override fun hashCode() = 31 * privateKeyPkcs8.contentHashCode() + publicKey.hashCode()
}

object MemberRecoveryPackets {
    private val parameters: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    }
    fun generateKeyPair(): MemberRecoveryKeyPair {
        val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        return MemberRecoveryKeyPair(pair.private.encoded, encodePublic(pair.public as ECPublicKey))
    }
    fun restoreKeyPair(privateKeyPkcs8: ByteArray, publicKey: String): MemberRecoveryKeyPair = try {
        val privateKey = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(privateKeyPkcs8)); val decodedPublic = decodePublic(publicKey)
        val probe = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val fromPrivate = KeyAgreement.getInstance("ECDH").apply { init(privateKey); doPhase(probe.public, true) }.generateSecret()
        val fromPublic = KeyAgreement.getInstance("ECDH").apply { init(probe.private); doPhase(decodedPublic, true) }.generateSecret()
        if (!MessageDigest.isEqual(fromPrivate, fromPublic)) throw MemberFailure.Storage
        MemberRecoveryKeyPair(privateKeyPkcs8.copyOf(), publicKey)
    } catch (failure: Exception) { if (failure is MemberFailure) throw failure else throw MemberFailure.Storage }
    fun seal(clear: ByteArray, recipientPublicKey: String, context: MemberRecoveryPacketContext): String {
        if (clear.isEmpty() || clear.size > 1024) throw MemberFailure.Malformed
        return try {
            val recipient = decodePublic(recipientPublicKey); val ephemeral = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
            val shared = KeyAgreement.getInstance("ECDH").apply { init(ephemeral.private); doPhase(recipient, true) }.generateSecret()
            val salt = ByteArray(32).also(SecureRandom()::nextBytes); val aad = aad(context); val key = hkdf(shared, salt, aad)
            val nonce = ByteArray(12).also(SecureRandom()::nextBytes); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce)); cipher.updateAAD(aad)
            val objectValue = mapOf(
                "profile" to JsonPrimitive("atarasy.member-recovery-packet.1"), "ephemeralPublicKey" to JsonPrimitive(encodePublic(ephemeral.public as ECPublicKey)),
                "salt" to JsonPrimitive(MemberPrivateNodeCodec.b64(salt)), "nonce" to JsonPrimitive(MemberPrivateNodeCodec.b64(nonce)),
                "ciphertext" to JsonPrimitive(MemberPrivateNodeCodec.b64(cipher.doFinal(clear))),
            )
            MemberPrivateNodeCodec.b64(JsonObject(objectValue.toSortedMap()).toString().toByteArray())
        } catch (failure: Exception) { if (failure is MemberFailure) throw failure else throw MemberFailure.Storage }
    }
    fun open(encoded: String, recipient: MemberRecoveryKeyPair, context: MemberRecoveryPacketContext): ByteArray {
        return try {
            val packetBytes = MemberPrivateNodeCodec.data(encoded); if (packetBytes.size !in 96..2048) throw MemberFailure.Malformed
            val row = Json.parseToJsonElement(packetBytes.toString(Charsets.UTF_8)).jsonObject
            if (row.keys != setOf("profile", "ephemeralPublicKey", "salt", "nonce", "ciphertext") || row.string("profile") != "atarasy.member-recovery-packet.1") throw MemberFailure.Malformed
            val salt = MemberPrivateNodeCodec.data(row.string("salt")); val nonce = MemberPrivateNodeCodec.data(row.string("nonce")); val sealed = MemberPrivateNodeCodec.data(row.string("ciphertext"))
            if (salt.size != 32 || nonce.size != 12 || sealed.size !in 17..1040) throw MemberFailure.Malformed
            val privateKey = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(recipient.privateKeyPkcs8))
            val shared = KeyAgreement.getInstance("ECDH").apply { init(privateKey); doPhase(decodePublic(row.string("ephemeralPublicKey")), true) }.generateSecret()
            val aad = aad(context); val key = hkdf(shared, salt, aad); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce)); cipher.updateAAD(aad); cipher.doFinal(sealed)
        } catch (failure: Exception) { if (failure is MemberFailure) throw failure else throw MemberFailure.Storage }
    }
    fun keyDigest(publicKey: String) = MemberPrivateNodeCodec.b64(MessageDigest.getInstance("SHA-256").digest(JsonArray(listOf(JsonPrimitive("atarasy.member-recovery-key.1"), JsonPrimitive(publicKey))).toString().toByteArray()))
    private fun aad(value: MemberRecoveryPacketContext): ByteArray {
        if (listOf(value.purpose, value.owner, value.recoverer, value.reference).any { it.isEmpty() } || value.epoch <= 0) throw MemberFailure.Malformed
        return JsonArray(listOf(JsonPrimitive("atarasy.member-recovery-packet.1"), JsonPrimitive(value.purpose), JsonPrimitive(value.owner), JsonPrimitive(value.recoverer), JsonPrimitive(value.reference), JsonPrimitive(value.epoch.toString()))).toString().toByteArray()
    }
    private fun hkdf(shared: ByteArray, salt: ByteArray, info: ByteArray): ByteArray {
        val extract = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(salt, "HmacSHA256")) }.doFinal(shared)
        return Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(extract, "HmacSHA256")) }.doFinal(info + byteArrayOf(1)).copyOf(32)
    }
    private fun encodePublic(key: ECPublicKey): String = MemberPrivateNodeCodec.b64(byteArrayOf(4) + fixed(key.w.affineX) + fixed(key.w.affineY))
    private fun decodePublic(encoded: String): java.security.PublicKey {
        val bytes = MemberPrivateNodeCodec.data(encoded); if (bytes.size != 65 || bytes[0] != 4.toByte()) throw MemberFailure.Malformed
        val point = ECPoint(BigInteger(1, bytes.copyOfRange(1, 33)), BigInteger(1, bytes.copyOfRange(33, 65)))
        return try { KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, parameters)) } catch (_: Exception) { throw MemberFailure.Malformed }
    }
    private fun fixed(value: BigInteger) = value.toByteArray().let { bytes -> when { bytes.size == 32 -> bytes; bytes.size == 33 && bytes[0] == 0.toByte() -> bytes.copyOfRange(1, 33); bytes.size < 32 -> ByteArray(32 - bytes.size) + bytes; else -> throw MemberFailure.Storage } }
    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.let { if (!it.isString) throw MemberFailure.Malformed; it.content }
}
