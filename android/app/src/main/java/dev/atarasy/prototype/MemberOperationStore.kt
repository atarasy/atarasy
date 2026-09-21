package dev.atarasy.prototype

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

data class MemberOperationHandle(
    val id: String,
    val operationProfile: String,
    val environment: String,
    val origin: String,
    val sessionId: String,
    val household: String,
    val presenter: String,
    val offer: String,
    val canonical: String,
    val expiresAt: Long,
    val requestDigest: String,
    val reviewedRevision: String,
    val challenge: String,
    val credentialId: String,
    val attempted: Boolean = false,
    val confirmationFingerprint: String? = null,
    val digitalTermsDigest: String? = null,
) {
    fun claimed(signature: String): MemberOperationHandle = copy(attempted = true, confirmationFingerprint = Canonical.digest(signature))
}

interface MemberOperationStore {
    fun save(handle: MemberOperationHandle)
    fun load(id: String): MemberOperationHandle?
    fun handles(): List<MemberOperationHandle>
    fun claim(handle: MemberOperationHandle, signature: String)
}

object MemberOperationCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val keys = setOf(
        "profile", "id", "operationProfile", "environment", "origin", "sessionId", "household", "presenter", "offer", "canonical",
        "expiresAt", "requestDigest", "reviewedRevision", "challenge", "credentialId", "attempted", "confirmationFingerprint", "digitalTermsDigest",
    )

    fun encode(value: MemberOperationHandle): ByteArray = buildJsonObject {
        put("profile", JsonPrimitive("atarasy.android-operation.1")); put("id", JsonPrimitive(value.id)); put("operationProfile", JsonPrimitive(value.operationProfile))
        put("environment", JsonPrimitive(value.environment)); put("origin", JsonPrimitive(value.origin)); put("sessionId", JsonPrimitive(value.sessionId))
        put("household", JsonPrimitive(value.household)); put("presenter", JsonPrimitive(value.presenter)); put("offer", JsonPrimitive(value.offer)); put("canonical", JsonPrimitive(value.canonical))
        put("expiresAt", JsonPrimitive(value.expiresAt)); put("requestDigest", JsonPrimitive(value.requestDigest)); put("reviewedRevision", JsonPrimitive(value.reviewedRevision))
        put("challenge", JsonPrimitive(value.challenge)); put("credentialId", JsonPrimitive(value.credentialId)); put("attempted", JsonPrimitive(value.attempted))
        put("confirmationFingerprint", value.confirmationFingerprint?.let(::JsonPrimitive) ?: JsonNull)
        put("digitalTermsDigest", value.digitalTermsDigest?.let(::JsonPrimitive) ?: JsonNull)
    }.toString().toByteArray()

    fun decode(bytes: ByteArray): MemberOperationHandle = try {
        val root = json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).let { it as JsonObject }; require(root.keys == keys)
        fun string(key: String) = root.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        fun optional(key: String) = root.getValue(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(it.isString); it.content }
        require(string("profile") == "atarasy.android-operation.1")
        MemberOperationHandle(
            string("id"), string("operationProfile"), string("environment"), string("origin"), string("sessionId"), string("household"),
            string("presenter"), string("offer"), string("canonical"), root.getValue("expiresAt").jsonPrimitive.let { require(!it.isString); it.long },
            string("requestDigest"), string("reviewedRevision"), string("challenge"), string("credentialId"),
            root.getValue("attempted").jsonPrimitive.let { require(!it.isString); it.content.toBooleanStrict() }, optional("confirmationFingerprint"), optional("digitalTermsDigest"),
        ).also(::validate)
    } catch (failure: Exception) { if (failure is MemberFailure) throw failure else throw MemberFailure.Storage }

    fun validate(value: MemberOperationHandle) {
        require(UUID.fromString(value.id).toString() == value.id)
        require(value.operationProfile in setOf("atarasy.member-decision-authorisation.1", "atarasy.member-statement-authorisation.1", "atarasy.member-withdrawal-authorisation.1"))
        require(value.environment.isNotEmpty() && value.origin.startsWith("https://") && value.sessionId.isNotEmpty() && value.household.isNotEmpty() && value.presenter.isNotEmpty() && value.offer.isNotEmpty() && value.canonical.isNotEmpty())
        require(value.expiresAt in 0..Canonical.MAXIMUM_INTEGER)
        require(Regex("^[a-f0-9]{64}$").matches(value.requestDigest) && Regex("^[a-f0-9]{64}$").matches(value.reviewedRevision))
        require(Regex("^[A-Za-z0-9_-]{43}$").matches(value.challenge) && value.credentialId.isNotEmpty())
        require(value.attempted == (value.confirmationFingerprint != null))
        require(value.confirmationFingerprint == null || Regex("^[a-f0-9]{64}$").matches(value.confirmationFingerprint))
        require(value.digitalTermsDigest == null || Regex("^[a-f0-9]{64}$").matches(value.digitalTermsDigest))
    }
}

class EncryptedFileMemberOperationStore(
    private val directory: File,
    private val environment: MemberEnvironment,
    private val cipher: EnvelopeCipher,
) : MemberOperationStore {
    private val lock = Any()
    init { require(directory.exists() || directory.mkdirs()) }

    override fun save(handle: MemberOperationHandle) = synchronized(lock) {
        validateScope(handle)
        val existing = read(handle.id)
        if (existing != null && existing != handle) throw MemberFailure.Storage
        if (existing == null) write(handle)
    }

    override fun load(id: String): MemberOperationHandle? = synchronized(lock) { read(id) }

    override fun handles(): List<MemberOperationHandle> = synchronized(lock) {
        val files = directory.listFiles { file -> file.isFile && file.extension == "operation" }?.sortedBy { it.name } ?: emptyList()
        if (files.size > 10_000) throw MemberFailure.Storage
        files.map { read(it.nameWithoutExtension) ?: throw MemberFailure.Storage }
    }

    override fun claim(handle: MemberOperationHandle, signature: String) = synchronized(lock) {
        if (signature.isEmpty() || signature.toByteArray().size > 16_384) throw MemberFailure.Malformed
        val canonical = sequenceOf(
            runCatching { Base64.getUrlDecoder().decode(signature).let { it.isNotEmpty() && Base64.getUrlEncoder().withoutPadding().encodeToString(it) == signature } }.getOrDefault(false),
            runCatching { Base64.getDecoder().decode(signature).let { it.isNotEmpty() && Base64.getEncoder().encodeToString(it) == signature } }.getOrDefault(false),
        ).any { it }
        if (!canonical) throw MemberFailure.Malformed
        val current = read(handle.id)
        if (current != handle || current.attempted) throw MemberFailure.Busy
        write(current.claimed(signature))
    }

    private fun read(id: String): MemberOperationHandle? {
        canonicalId(id); val target = File(directory, "$id.operation")
        if (!target.exists()) return null
        if (!target.isFile || target.length() !in 1..1_048_640) throw MemberFailure.Storage
        return try {
            val value = MemberOperationCodec.decode(cipher.open(target.readBytes(), aad(id)))
            if (value.id != id) throw MemberFailure.Storage
            validateScope(value); value
        } catch (failure: Exception) { if (failure is MemberFailure) throw failure else throw MemberFailure.Storage }
    }

    private fun write(handle: MemberOperationHandle) {
        validateScope(handle); val target = File(directory, "${handle.id}.operation"); val temporary = File(directory, ".${handle.id}.${System.nanoTime()}.tmp")
        try {
            val envelope = cipher.seal(MemberOperationCodec.encode(handle), aad(handle.id))
            FileOutputStream(temporary).use { it.write(envelope); it.fd.sync() }
            try { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            catch (_: Exception) { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
        } catch (failure: Exception) { temporary.delete(); if (failure is MemberFailure) throw failure else throw MemberFailure.Storage }
    }

    private fun validateScope(value: MemberOperationHandle) {
        try { MemberOperationCodec.validate(value) } catch (_: Exception) { throw MemberFailure.Storage }
        if (value.environment != environment.name || value.origin != environment.origin) throw MemberFailure.Storage
    }
    private fun canonicalId(id: String) { try { require(UUID.fromString(id).toString() == id) } catch (_: Exception) { throw MemberFailure.Storage } }
    private fun aad(id: String) = listOf("atarasy.android-operation-aad.1", environment.name, environment.origin, id).joinToString("\n").toByteArray()
}
