package dev.atarasy.prototype

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

interface MemberRecoveryMaterialVault {
    fun agreementKey(scope: String, create: Boolean): MemberRecoveryKeyPair?
    fun requesterKey(scope: String, create: Boolean): MemberRecoveryKeyPair?
    fun saveDeviceShare(scope: String, epoch: Long, share: MemberRecoveryShare)
    fun deviceShare(scope: String, epoch: Long): MemberRecoveryShare?
    fun removeRequesterKey(scope: String)
}

class EncryptedFileRecoveryMaterialVault(private val directory: File, private val cipher: EnvelopeCipher) : MemberRecoveryMaterialVault {
    private val lock = Any(); private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    init { if (!directory.exists() && !directory.mkdirs()) throw MemberFailure.Storage }
    override fun agreementKey(scope: String, create: Boolean) = pair("agreement", scope, create)
    override fun requesterKey(scope: String, create: Boolean) = pair("requester", scope, create)
    override fun saveDeviceShare(scope: String, epoch: Long, share: MemberRecoveryShare) = synchronized(lock) {
        validate(scope); if (epoch <= 0 || share.participant != MemberRecoveryParticipant.DEVICE) throw MemberFailure.Storage
        val bytes = buildJsonObject {
            put("profile", JsonPrimitive("atarasy.android-recovery-share.1")); put("epoch", JsonPrimitive(epoch)); put("share", JsonPrimitive(MemberPrivateNodeCodec.b64(share.bytes)))
        }.toString().toByteArray()
        save(name("device", scope, epoch), bytes)
    }
    override fun deviceShare(scope: String, epoch: Long): MemberRecoveryShare? = synchronized(lock) {
        validate(scope); if (epoch <= 0) throw MemberFailure.Storage
        val bytes = read(name("device", scope, epoch)) ?: return@synchronized null
        try {
            val root = json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
            require(root.keys == setOf("profile", "epoch", "share") && root.text("profile") == "atarasy.android-recovery-share.1" && root.number("epoch") == epoch)
            MemberRecoveryShare(MemberRecoveryParticipant.DEVICE, MemberPrivateNodeCodec.data(root.text("share")))
        } catch (_: Exception) { throw MemberFailure.Storage }
    }
    override fun removeRequesterKey(scope: String) = synchronized(lock) {
        validate(scope); val file = File(directory, name("requester", scope)); if (file.exists() && !file.delete()) throw MemberFailure.Storage
    }
    private fun pair(kind: String, scope: String, create: Boolean): MemberRecoveryKeyPair? = synchronized(lock) {
        validate(scope); val filename = name(kind, scope); val existing = read(filename)
        if (existing != null) return@synchronized decodePair(existing)
        if (!create) return@synchronized null
        val pair = MemberRecoveryPackets.generateKeyPair(); val bytes = buildJsonObject {
            put("profile", JsonPrimitive("atarasy.android-recovery-key.1")); put("privateKey", JsonPrimitive(MemberPrivateNodeCodec.b64(pair.privateKeyPkcs8))); put("publicKey", JsonPrimitive(pair.publicKey))
        }.toString().toByteArray(); save(filename, bytes); pair
    }
    private fun decodePair(bytes: ByteArray): MemberRecoveryKeyPair = try {
        val root = json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
        require(root.keys == setOf("profile", "privateKey", "publicKey") && root.text("profile") == "atarasy.android-recovery-key.1")
        MemberRecoveryPackets.restoreKeyPair(MemberPrivateNodeCodec.data(root.text("privateKey")), root.text("publicKey"))
    } catch (_: Exception) { throw MemberFailure.Storage }
    private fun save(filename: String, clear: ByteArray) {
        val existing = read(filename); if (existing != null) { if (!existing.contentEquals(clear)) throw MemberFailure.Storage; return }
        val target = File(directory, filename); val temporary = File(directory, ".$filename.${System.nanoTime()}.tmp")
        try {
            FileOutputStream(temporary).use { it.write(cipher.seal(clear, aad(filename))); it.fd.sync() }
            try { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE) }
            catch (_: Exception) { Files.move(temporary.toPath(), target.toPath()) }
        } catch (_: Exception) { temporary.delete(); throw MemberFailure.Storage }
    }
    private fun read(filename: String): ByteArray? {
        val file = File(directory, filename); if (!file.exists()) return null
        return try { cipher.open(file.readBytes(), aad(filename)) } catch (_: Exception) { throw MemberFailure.Storage }
    }
    private fun name(kind: String, scope: String, epoch: Long? = null) = listOfNotNull(kind, scope, epoch?.toString()).joinToString(".") + ".recovery"
    private fun aad(filename: String) = "atarasy.android-recovery-material.1\n$filename".toByteArray()
    private fun validate(scope: String) { if (!Regex("^[a-f0-9]{64}$").matches(scope)) throw MemberFailure.Storage }
    private fun JsonObject.text(key: String) = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.let { require(!it.isString); it.long }
}
