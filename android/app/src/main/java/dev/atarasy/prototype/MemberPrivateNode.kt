package dev.atarasy.prototype

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

data class MemberPrivateNodeEnvelope(val profile: String = "atarasy.private-node-record.1", val nonce: String, val ciphertext: String)
data class MemberPrivateNodeRecord(val id: String, val revision: Long, val updatedAt: Long, val envelope: MemberPrivateNodeEnvelope)
data class MemberPrivateNodeIndex(val profile: String, val checkedAt: Long, val records: List<MemberPrivateNodeRecord>)
data class MemberPrivateNodeMove(val key: ByteArray, val source: List<MemberPrivateNodeRecord>, val target: List<MemberPrivateNodeRecord>, val clearDigests: Map<String, String>) {
    override fun equals(other: Any?) = other is MemberPrivateNodeMove && key.contentEquals(other.key) && source == other.source && target == other.target && clearDigests == other.clearDigests
    override fun hashCode() = 31 * key.contentHashCode() + source.hashCode()
}
enum class MemberPrivateNodeState { LOCKED, READY, RECOVERY_REQUIRED }

object MemberPrivateNodeCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    fun envelope(element: JsonElement): MemberPrivateNodeEnvelope = malformed {
        val row = element.jsonObject; require(row.keys == setOf("profile", "nonce", "ciphertext"))
        val value = MemberPrivateNodeEnvelope(row.string("profile"), row.string("nonce"), row.string("ciphertext"))
        require(value.profile == "atarasy.private-node-record.1" && data(value.nonce).size == 12)
        require(data(value.ciphertext).size in 17..12_304); value
    }
    fun record(element: JsonElement): MemberPrivateNodeRecord = malformed {
        val row = element.jsonObject; require(row.keys == setOf("id", "revision", "updatedAt", "envelope"))
        val value = MemberPrivateNodeRecord(row.string("id"), row.number("revision"), row.number("updatedAt"), envelope(row.getValue("envelope")))
        require(UUID.fromString(value.id).toString() == value.id && value.revision > 0); value
    }
    fun index(bytes: ByteArray): MemberPrivateNodeIndex = malformed {
        val root = json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
        require(root.keys == setOf("profile", "checkedAt", "records") && root.string("profile") == "atarasy.private-node-index.1")
        val rows = root.getValue("records").jsonArray.map(::record); require(rows.size <= 10_000 && rows.map { it.id }.distinct().size == rows.size && rows.map { it.id } == rows.map { it.id }.sorted())
        MemberPrivateNodeIndex("atarasy.private-node-index.1", root.number("checkedAt"), rows)
    }
    fun envelopeJson(value: MemberPrivateNodeEnvelope) = buildJsonObject {
        put("profile", JsonPrimitive(value.profile)); put("nonce", JsonPrimitive(value.nonce)); put("ciphertext", JsonPrimitive(value.ciphertext))
    }
    fun b64(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    fun data(value: String): ByteArray {
        if (!Regex("^[A-Za-z0-9_-]+$").matches(value) || value.length % 4 == 1) throw MemberFailure.Malformed
        return try { Base64.getUrlDecoder().decode(value).also { if (b64(it) != value) throw MemberFailure.Malformed } } catch (e: MemberFailure) { throw e } catch (_: Exception) { throw MemberFailure.Malformed }
    }
    fun scope(environment: MemberEnvironment, household: String) = Canonical.digest(JsonArray(listOf(
        JsonPrimitive("atarasy.private-node-scope.1"), JsonPrimitive(environment.name), JsonPrimitive(environment.origin), JsonPrimitive(household),
    )).toString())
    fun aad(environment: MemberEnvironment, household: String, id: String, revision: Long) = JsonArray(listOf(
        JsonPrimitive("atarasy.private-node-record.1"), JsonPrimitive(environment.name), JsonPrimitive(environment.origin), JsonPrimitive(household), JsonPrimitive(id), JsonPrimitive(revision.toString()),
    )).toString().toByteArray()
    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: MemberFailure) { throw e } catch (_: Exception) { throw MemberFailure.Malformed }
}

class MemberPrivateNodeCrypto(key: ByteArray) {
    private val secret = SecretKeySpec(key.copyOf().also { if (it.size != 32) throw MemberFailure.Storage }, "AES")
    fun seal(clear: ByteArray, environment: MemberEnvironment, household: String, id: String, revision: Long): MemberPrivateNodeEnvelope {
        if (clear.isEmpty() || clear.size > 12_288 || !canonicalId(id) || revision <= 0) throw MemberFailure.Malformed
        return try {
            val nonce = ByteArray(12).also(SecureRandom()::nextBytes); val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secret, GCMParameterSpec(128, nonce)); cipher.updateAAD(MemberPrivateNodeCodec.aad(environment, household, id, revision))
            MemberPrivateNodeEnvelope(nonce = MemberPrivateNodeCodec.b64(nonce), ciphertext = MemberPrivateNodeCodec.b64(cipher.doFinal(clear)))
        } catch (failure: Exception) { if (failure is MemberFailure) throw failure else throw MemberFailure.Storage }
    }
    fun open(record: MemberPrivateNodeRecord, environment: MemberEnvironment, household: String): ByteArray = try {
        if (record.envelope.profile != "atarasy.private-node-record.1" || !canonicalId(record.id) || record.revision <= 0) throw MemberFailure.Malformed
        val nonce = MemberPrivateNodeCodec.data(record.envelope.nonce); val sealed = MemberPrivateNodeCodec.data(record.envelope.ciphertext)
        if (nonce.size != 12 || sealed.size !in 17..12_304) throw MemberFailure.Malformed
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, nonce))
        cipher.updateAAD(MemberPrivateNodeCodec.aad(environment, household, record.id, record.revision)); cipher.doFinal(sealed)
    } catch (failure: Exception) { if (failure is MemberFailure) throw failure else throw MemberFailure.Storage }
    private fun canonicalId(id: String) = try { UUID.fromString(id).toString() == id } catch (_: Exception) { false }
}

interface MemberPrivateNodeKeyVault {
    fun load(scope: String): ByteArray?
    fun create(scope: String): ByteArray
    fun install(scope: String, key: ByteArray)
}

class EncryptedFilePrivateNodeKeyVault(private val directory: File, private val cipher: EnvelopeCipher) : MemberPrivateNodeKeyVault {
    private val lock = Any()
    init { if (!directory.exists() && !directory.mkdirs()) throw MemberFailure.Storage }
    override fun load(scope: String): ByteArray? = synchronized(lock) {
        validate(scope); val file = File(directory, "$scope.key"); if (!file.exists()) return@synchronized null
        try { cipher.open(file.readBytes(), aad(scope)).also { require(it.size == 32) } } catch (_: Exception) { throw MemberFailure.Storage }
    }
    override fun create(scope: String): ByteArray = synchronized(lock) {
        load(scope)?.let { return@synchronized it }; ByteArray(32).also(SecureRandom()::nextBytes).also { write(scope, it) }
    }
    override fun install(scope: String, key: ByteArray) = synchronized(lock) {
        validate(scope); if (key.size != 32 || load(scope) != null) throw MemberFailure.Storage; write(scope, key)
    }
    private fun write(scope: String, key: ByteArray) {
        val target = File(directory, "$scope.key"); val temporary = File(directory, ".$scope.${System.nanoTime()}.tmp")
        try {
            FileOutputStream(temporary).use { it.write(cipher.seal(key, aad(scope))); it.fd.sync() }
            try { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            catch (_: Exception) { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
        } catch (_: Exception) { temporary.delete(); throw MemberFailure.Storage }
    }
    private fun validate(scope: String) { if (!Regex("^[a-f0-9]{64}$").matches(scope)) throw MemberFailure.Storage }
    private fun aad(scope: String) = "atarasy.android-private-node-key.1\n$scope".toByteArray()
}

class MemberPrivateNodeRemote(private val sessions: MemberSessionClient) {
    suspend fun records(): MemberPrivateNodeIndex { val (reply, _) = sessions.readWithSession("/member/private-node/records"); json200(reply); return MemberPrivateNodeCodec.index(reply.body) }
    suspend fun record(id: String): MemberPrivateNodeRecord {
        canonicalId(id); val (reply, _) = sessions.readWithSession("/member/private-node/records/$id"); json200(reply)
        return parseRecord(reply.body).also { if (it.id != id) throw MemberFailure.ScopeMismatch }
    }
    suspend fun write(id: String, expectedRevision: Long, envelope: MemberPrivateNodeEnvelope): MemberPrivateNodeRecord {
        canonicalId(id); if (expectedRevision !in 0 until Canonical.MAXIMUM_INTEGER) throw MemberFailure.Malformed; MemberPrivateNodeCodec.envelope(MemberPrivateNodeCodec.envelopeJson(envelope))
        val body = buildJsonObject { put("expectedRevision", JsonPrimitive(expectedRevision)); put("envelope", MemberPrivateNodeCodec.envelopeJson(envelope)) }.toString().toByteArray()
        val (reply, _) = sessions.readWithSession("/member/private-node/records/$id", body = body); json200(reply)
        return parseRecord(reply.body).also { if (it.id != id || it.revision != expectedRevision + 1 || it.envelope != envelope) throw MemberFailure.ScopeMismatch }
    }
    private fun parseRecord(bytes: ByteArray) = try { MemberPrivateNodeCodec.record(Json.parseToJsonElement(bytes.toString(Charsets.UTF_8))) } catch (e: MemberFailure) { throw e } catch (_: Exception) { throw MemberFailure.Malformed }
    private fun canonicalId(id: String) { try { require(UUID.fromString(id).toString() == id) } catch (_: Exception) { throw MemberFailure.Malformed } }
    private fun json200(reply: MemberHttpResponse) { if (reply.status != 200) throw MemberFailure.Http(reply.status); if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed }
}

class MemberPrivateNode(
    private val environment: MemberEnvironment,
    private val remote: MemberPrivateNodeRemote,
    private val vault: MemberPrivateNodeKeyVault,
) {
    companion object { const val BOOTSTRAP_ID = "00000000-0000-4000-8000-000000000019"; val BOOTSTRAP = "{\"profile\":\"atarasy.private-node-bootstrap.1\"}".toByteArray() }
    private val mutex = Mutex(); private var session: MemberSessionInfo? = null; private var crypto: MemberPrivateNodeCrypto? = null
    var state = MemberPrivateNodeState.LOCKED; private set
    suspend fun open(session: MemberSessionInfo): MemberPrivateNodeState = mutex.withLock {
        lockInternal(); val index = remote.records(); val scope = MemberPrivateNodeCodec.scope(environment, session.household)
        var key = vault.load(scope)
        if (key == null && index.records.isNotEmpty()) { state = MemberPrivateNodeState.RECOVERY_REQUIRED; return@withLock state }
        if (key == null) key = vault.create(scope)
        val codec = MemberPrivateNodeCrypto(key)
        if (index.records.isEmpty()) {
            val envelope = codec.seal(BOOTSTRAP, environment, session.household, BOOTSTRAP_ID, 1)
            val record = remote.write(BOOTSTRAP_ID, 0, envelope); if (!codec.open(record, environment, session.household).contentEquals(BOOTSTRAP)) throw MemberFailure.ScopeMismatch
        } else verify(index.records, codec, session.household)
        this.session = session; crypto = codec; state = MemberPrivateNodeState.READY; state
    }
    suspend fun read(id: String): ByteArray = mutex.withLock {
        val active = session ?: throw MemberFailure.Storage; val codec = crypto ?: throw MemberFailure.Storage
        codec.open(remote.record(id), environment, active.household)
    }
    suspend fun write(id: String = UUID.randomUUID().toString(), expectedRevision: Long, clear: ByteArray): MemberPrivateNodeRecord = mutex.withLock {
        val active = session ?: throw MemberFailure.Storage; val codec = crypto ?: throw MemberFailure.Storage
        val envelope = codec.seal(clear, environment, active.household, id, expectedRevision + 1); val record = remote.write(id, expectedRevision, envelope)
        if (!codec.open(record, environment, active.household).contentEquals(clear)) throw MemberFailure.ScopeMismatch; record
    }
    suspend fun recoveryKey(expected: MemberSessionInfo): ByteArray = mutex.withLock {
        if (state != MemberPrivateNodeState.READY || session != expected) throw MemberFailure.Storage
        vault.load(MemberPrivateNodeCodec.scope(environment, expected.household)) ?: throw MemberFailure.Storage
    }
    suspend fun prepareMove(target: MemberEnvironment, expected: MemberSessionInfo): MemberPrivateNodeMove = mutex.withLock {
        val active = session ?: throw MemberFailure.Storage; val sourceCrypto = crypto ?: throw MemberFailure.Storage
        if (state != MemberPrivateNodeState.READY || active != expected || target.origin == environment.origin) throw MemberFailure.Storage
        val key = vault.load(MemberPrivateNodeCodec.scope(environment, expected.household)) ?: throw MemberFailure.Storage
        val index = remote.records(); verify(index.records, sourceCrypto, expected.household)
        val targetCrypto = MemberPrivateNodeCrypto(key); val targetRecords = mutableListOf<MemberPrivateNodeRecord>(); val digests = linkedMapOf<String, String>()
        index.records.forEach { record ->
            val clear = sourceCrypto.open(record, environment, expected.household)
            val envelope = targetCrypto.seal(clear, target, expected.household, record.id, record.revision)
            targetRecords += record.copy(envelope = envelope)
            digests[record.id] = java.security.MessageDigest.getInstance("SHA-256").digest(clear).joinToString("") { "%02x".format(it) }
        }
        MemberPrivateNodeMove(key.copyOf(), index.records, targetRecords, digests)
    }
    suspend fun installRecoveredKey(key: ByteArray, expected: MemberSessionInfo) = mutex.withLock {
        if (state != MemberPrivateNodeState.RECOVERY_REQUIRED || key.size != 32) throw MemberFailure.Storage
        val index = remote.records(); if (index.records.isEmpty()) throw MemberFailure.Storage; val codec = MemberPrivateNodeCrypto(key)
        verify(index.records, codec, expected.household); vault.install(MemberPrivateNodeCodec.scope(environment, expected.household), key)
        session = expected; crypto = codec; state = MemberPrivateNodeState.READY
    }
    suspend fun lock() = mutex.withLock { lockInternal() }
    private fun lockInternal() { session = null; crypto = null; state = MemberPrivateNodeState.LOCKED }
    private fun verify(records: List<MemberPrivateNodeRecord>, codec: MemberPrivateNodeCrypto, household: String) {
        records.forEach { record -> val clear = codec.open(record, environment, household); if (record.id == BOOTSTRAP_ID && !clear.contentEquals(BOOTSTRAP)) throw MemberFailure.ScopeMismatch }
    }
}
