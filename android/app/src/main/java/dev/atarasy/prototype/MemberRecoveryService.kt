package dev.atarasy.prototype

import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

data class MemberRecoveryKeyStatus(val profile: String, val household: String, val publicKey: String?, val updatedAt: Long?)
data class MemberRecoveryParticipantKey(val profile: String, val household: String, val publicKey: String, val keyDigest: String, val updatedAt: Long)
data class MemberRecoveryConfigurationDraft(val epoch: Long, val recoverer: String, val keyDigest: String, val hostShare: String, val recovererPacket: String, val noticeChannel: String)
data class MemberRecoveryConfiguration(
    val profile: String, val owner: String, val configured: Boolean, val recoverer: String?, val recovererKeyDigest: String?, val keyDigest: String?,
    val epoch: Long?, val createdAt: Long?, val updatedAt: Long?,
)
data class MemberRecoveryRequest(
    val profile: String, val id: String, val owner: String, val recoverer: String, val epoch: Long, val requesterPublicKey: String, val state: String,
    val createdAt: Long, val updatedAt: Long, val recovererPacket: String?, val release: String?, val hostShare: String?, val keyDigest: String?,
)
data class MemberRecoveryLogEvent(
    val id: String, val owner: String, val recovery: String, val recoverer: String, val state: String, val occurredAt: Long,
    val deliveredAt: Long?, val receipt: String?,
)
data class MemberRecoveryLog(val profile: String, val owner: String, val events: List<MemberRecoveryLogEvent>)
data class MemberRecoveryCeremony(val id: String, val expiresAt: Long, val publicKey: JsonObject, val publicKeyJson: String, val credentialId: String)
data class PreparedMemberRecoveryKey(val recoveryPublicKey: String, val ceremony: MemberRecoveryCeremony, val sessionId: String)
data class PreparedMemberRecoveryConfiguration(val draft: MemberRecoveryConfigurationDraft, val recovererKeyDigest: String, val ceremony: MemberRecoveryCeremony, val sessionId: String)
data class PreparedMemberRecoveryApproval(val request: MemberRecoveryRequest, val release: String, val ceremony: MemberRecoveryCeremony, val sessionId: String)

object MemberRecoveryWire {
    val requestKeys = setOf("profile", "id", "owner", "recoverer", "epoch", "requesterPublicKey", "state", "createdAt", "updatedAt", "recovererPacket", "release", "hostShare", "keyDigest")
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    fun key(value: String) = runCatching { MemberPrivateNodeCodec.data(value).let { it.size == 65 && it[0] == 4.toByte() } }.getOrDefault(false)
    fun b64(value: String, range: IntRange) = runCatching { MemberPrivateNodeCodec.data(value).size in range }.getOrDefault(false)
    fun keyStatus(bytes: ByteArray, household: String): MemberRecoveryKeyStatus = malformed {
        val row = objectOf(bytes); require(row.keys == setOf("profile", "household", "publicKey", "updatedAt"))
        val value = MemberRecoveryKeyStatus(row.text("profile"), row.text("household"), row.optionalText("publicKey"), row.optionalNumber("updatedAt"))
        require(value.profile == "atarasy.member-recovery-key.1" && value.household == household && (value.publicKey == null) == (value.updatedAt == null)) { "scope" }
        require(value.publicKey?.let(::key) != false); value
    }
    fun participant(bytes: ByteArray, expected: String): MemberRecoveryParticipantKey = malformed {
        val row = objectOf(bytes); require(row.keys == setOf("profile", "household", "publicKey", "keyDigest", "updatedAt"))
        val value = MemberRecoveryParticipantKey(row.text("profile"), row.text("household"), row.text("publicKey"), row.text("keyDigest"), row.number("updatedAt"))
        require(value.profile == "atarasy.member-recovery-participant.1" && value.household == expected && key(value.publicKey) && value.keyDigest == MemberRecoveryPackets.keyDigest(value.publicKey)) { "scope" }; value
    }
    fun configuration(bytes: ByteArray, household: String): MemberRecoveryConfiguration = malformed {
        val row = objectOf(bytes); require(row.keys == setOf("profile", "owner", "configured", "recoverer", "recovererKeyDigest", "keyDigest", "epoch", "createdAt", "updatedAt"))
        val configured = row.boolean("configured")
        val value = MemberRecoveryConfiguration(row.text("profile"), row.text("owner"), configured, row.optionalText("recoverer"), row.optionalText("recovererKeyDigest"), row.optionalText("keyDigest"), row.optionalNumber("epoch"), row.optionalNumber("createdAt"), row.optionalNumber("updatedAt"))
        require(value.profile == "atarasy.member-recovery-configuration.1" && value.owner == household) { "scope" }
        if (configured) require(!value.recoverer.isNullOrEmpty() && value.recoverer != household && value.recovererKeyDigest?.let { b64(it, 32..32) } == true && value.keyDigest?.let { b64(it, 32..32) } == true &&
            value.epoch != null && value.epoch > 0 && value.createdAt != null && value.updatedAt != null && value.updatedAt >= value.createdAt)
        else require(listOf(value.recoverer, value.recovererKeyDigest, value.keyDigest, value.epoch, value.createdAt, value.updatedAt).all { it == null })
        value
    }
    fun request(element: JsonElement, household: String): MemberRecoveryRequest = malformed {
        val row = element.jsonObject; require(row.keys == requestKeys)
        val value = MemberRecoveryRequest(
            row.text("profile"), row.text("id"), row.text("owner"), row.text("recoverer"), row.number("epoch"), row.text("requesterPublicKey"), row.text("state"),
            row.number("createdAt"), row.number("updatedAt"), row.optionalText("recovererPacket"), row.optionalText("release"), row.optionalText("hostShare"), row.optionalText("keyDigest"),
        )
        require(value.profile == "atarasy.member-recovery-request.1" && UUID.fromString(value.id).toString() == value.id && value.epoch > 0 && key(value.requesterPublicKey) && value.state in setOf("pending", "approved", "completed", "cancelled") && value.updatedAt >= value.createdAt)
        require(value.owner == household || value.recoverer == household) { "scope" }
        if (household == value.owner) {
            require(value.recovererPacket == null) { "scope" }
            if (value.state == "completed") require(value.release?.let { b64(it, 96..2048) } == true && value.hostShare?.let { b64(it, 64..64) } == true && value.keyDigest?.let { b64(it, 32..32) } == true)
            else require(value.release == null && value.hostShare == null && value.keyDigest == null) { "scope" }
        } else {
            require(value.hostShare == null && value.keyDigest == null && value.recovererPacket?.let { b64(it, 96..2048) } == true) { "scope" }
            require(value.release == null || b64(value.release, 96..2048))
        }
        value
    }
    fun requests(bytes: ByteArray, household: String): List<MemberRecoveryRequest> = malformed {
        val row = objectOf(bytes); require(row.keys == setOf("profile", "checkedAt", "requests") && row.text("profile") == "atarasy.member-recovery-request-list.1")
        row.number("checkedAt"); val values = row.getValue("requests").jsonArray.map { request(it, household) }
        require(values.size <= 100 && values.map { it.id }.distinct().size == values.size && values.map { it.id } == values.map { it.id }.sorted()); values
    }
    fun log(bytes: ByteArray, household: String): MemberRecoveryLog = malformed {
        val row = objectOf(bytes); require(row.keys == setOf("profile", "owner", "events") && row.text("profile") == "atarasy.member-recovery-log.1" && row.text("owner") == household) { "scope" }
        val events = row.getValue("events").jsonArray.map { element ->
            val event = element.jsonObject; require(event.keys == setOf("id", "owner", "recovery", "recoverer", "state", "occurredAt", "deliveredAt", "receipt"))
            MemberRecoveryLogEvent(event.text("id"), event.text("owner"), event.text("recovery"), event.text("recoverer"), event.text("state"), event.number("occurredAt"), event.optionalNumber("deliveredAt"), event.optionalText("receipt")).also {
                require(UUID.fromString(it.id).toString() == it.id && UUID.fromString(it.recovery).toString() == it.recovery && it.owner == household && it.state in setOf("notice_pending", "completed")) { "scope" }
                require((it.state == "completed") == (it.deliveredAt != null && it.receipt != null))
            }
        }
        require(events.size <= 1_000 && events.map { it.id }.distinct().size == events.size); MemberRecoveryLog("atarasy.member-recovery-log.1", household, events)
    }
    fun ceremony(text: String, environment: MemberEnvironment, now: Long): MemberRecoveryCeremony = malformed {
        val root = json.parseToJsonElement(text).jsonObject; val id = root.text("id"); val expiry = root.number("expiresAt"); require(expiry > now)
        val publicKey = root.getValue("publicKey").jsonObject; require(publicKey.keys == setOf("challenge", "rpId", "timeout", "userVerification", "allowCredentials"))
        require(publicKey.text("rpId") == environment.relyingPartyId && publicKey.text("userVerification") == "required"); publicKey.number("timeout")
        val allowed = publicKey.getValue("allowCredentials").jsonArray; require(allowed.size == 1); val credential = allowed.single().jsonObject
        require(credential.keys == setOf("type", "id") && credential.text("type") == "public-key")
        MemberRecoveryCeremony(id, expiry, publicKey, MemberAuthenticationWire.rawObjectMember(text, "publicKey") ?: error("publicKey"), credential.text("id"))
    }
    fun assertion(assertionJson: String, ceremony: MemberRecoveryCeremony, environment: MemberEnvironment, acceptedOrigins: Set<String>): JsonObject = malformed {
        val assertion = json.parseToJsonElement(assertionJson).jsonObject; require(assertion.text("id") == ceremony.credentialId) { "scope" }
        val response = assertion.getValue("response").jsonObject; val encoded = response.text("clientDataJSON")
        val client = json.parseToJsonElement(Base64.getUrlDecoder().decode(encoded).toString(StandardCharsets.UTF_8)).jsonObject
        require(client.text("type") == "webauthn.get" && client.text("challenge") == ceremony.publicKey.text("challenge") && client.text("origin") in acceptedOrigins && !client.containsKey("topOrigin") &&
            (!client.containsKey("crossOrigin") || client["crossOrigin"] == JsonPrimitive(false))) { "scope" }; assertion
    }
    fun draftJson(value: MemberRecoveryConfigurationDraft) = buildJsonObject {
        put("epoch", JsonPrimitive(value.epoch)); put("recoverer", JsonPrimitive(value.recoverer)); put("keyDigest", JsonPrimitive(value.keyDigest)); put("hostShare", JsonPrimitive(value.hostShare)); put("recovererPacket", JsonPrimitive(value.recovererPacket)); put("noticeChannel", JsonPrimitive(value.noticeChannel))
    }
    fun objectOf(bytes: ByteArray) = try { json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
    private fun JsonObject.text(key: String) = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    private fun JsonObject.optionalText(key: String) = getValue(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(it.isString); it.content }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun JsonObject.optionalNumber(key: String) = getValue(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(!it.isString); it.long }.also { require(it == null || it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun JsonObject.boolean(key: String) = getValue(key).jsonPrimitive.let { require(!it.isString); it.content.toBooleanStrict() }
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: MemberFailure.ScopeMismatch) { throw e }
    catch (e: IllegalArgumentException) { if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed }
    catch (_: Exception) { throw MemberFailure.Malformed }
}

class MemberRecoveryService(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
    private val now: () -> Long = System::currentTimeMillis,
    private val acceptedOrigins: Set<String> = setOf(environment.origin),
) {
    suspend fun keyStatus(): MemberRecoveryKeyStatus { val (reply, session) = get("/member/recovery/key"); return MemberRecoveryWire.keyStatus(reply.body, session.household) }
    suspend fun prepareKey(publicKey: String): PreparedMemberRecoveryKey {
        if (!MemberRecoveryWire.key(publicKey)) throw MemberFailure.Malformed
        val body = buildJsonObject { put("publicKey", JsonPrimitive(publicKey)) }.toString().toByteArray(); val (reply, session) = post("/member/recovery/key/prepare", body)
        val text = reply.body.toString(Charsets.UTF_8); val root = MemberRecoveryWire.objectOf(reply.body)
        if (root.keys != setOf("profile", "household", "recoveryPublicKey", "id", "expiresAt", "publicKey") || root["profile"] != JsonPrimitive("atarasy.member-recovery-key-registration.1") || root["household"] != JsonPrimitive(session.household) || root["recoveryPublicKey"] != JsonPrimitive(publicKey)) throw MemberFailure.ScopeMismatch
        return PreparedMemberRecoveryKey(publicKey, MemberRecoveryWire.ceremony(text, environment, now()), session.id)
    }
    suspend fun registerKey(prepared: PreparedMemberRecoveryKey, assertionJson: String): MemberRecoveryKeyStatus {
        active(prepared.sessionId); val assertion = MemberRecoveryWire.assertion(assertionJson, prepared.ceremony, environment, acceptedOrigins)
        val body = buildJsonObject { put("preparation", JsonPrimitive(prepared.ceremony.id)); put("publicKey", JsonPrimitive(prepared.recoveryPublicKey)); put("assertion", assertion) }.toString().toByteArray()
        val (reply, session) = post("/member/recovery/key/register", body); return MemberRecoveryWire.keyStatus(reply.body, session.household).also { if (it.publicKey != prepared.recoveryPublicKey) throw MemberFailure.ScopeMismatch }
    }
    suspend fun participant(household: String): MemberRecoveryParticipantKey {
        if (household.isEmpty()) throw MemberFailure.Malformed; val body = buildJsonObject { put("household", JsonPrimitive(household)) }.toString().toByteArray()
        val (reply, _) = post("/member/recovery/participant", body); return MemberRecoveryWire.participant(reply.body, household)
    }
    suspend fun configuration(): MemberRecoveryConfiguration { val (reply, session) = get("/member/recovery/configuration"); return MemberRecoveryWire.configuration(reply.body, session.household) }
    suspend fun prepareConfiguration(draft: MemberRecoveryConfigurationDraft, recovererKeyDigest: String): PreparedMemberRecoveryConfiguration {
        if (!MemberRecoveryWire.b64(recovererKeyDigest, 32..32)) throw MemberFailure.Malformed
        val (reply, session) = post("/member/recovery/configuration/prepare", MemberRecoveryWire.draftJson(draft).toString().toByteArray())
        val text = reply.body.toString(Charsets.UTF_8); val root = MemberRecoveryWire.objectOf(reply.body)
        if (root.keys != setOf("profile", "configuration", "id", "expiresAt", "publicKey") || root["profile"] != JsonPrimitive("atarasy.member-recovery-configuration-review.1")) throw MemberFailure.Malformed
        val fixed = root.getValue("configuration").jsonObject
        val expected = MemberRecoveryWire.draftJson(draft) + mapOf("owner" to JsonPrimitive(session.household), "recovererKeyDigest" to JsonPrimitive(recovererKeyDigest))
        if (fixed != JsonObject(expected)) throw MemberFailure.ScopeMismatch
        return PreparedMemberRecoveryConfiguration(draft, recovererKeyDigest, MemberRecoveryWire.ceremony(text, environment, now()), session.id)
    }
    suspend fun submitConfiguration(prepared: PreparedMemberRecoveryConfiguration, assertionJson: String): MemberRecoveryConfiguration {
        active(prepared.sessionId); val assertion = MemberRecoveryWire.assertion(assertionJson, prepared.ceremony, environment, acceptedOrigins)
        val body = buildJsonObject { put("preparation", JsonPrimitive(prepared.ceremony.id)); put("configuration", MemberRecoveryWire.draftJson(prepared.draft)); put("assertion", assertion) }.toString().toByteArray()
        val (reply, session) = post("/member/recovery/configuration/submit", body); return MemberRecoveryWire.configuration(reply.body, session.household).also {
            if (it.epoch != prepared.draft.epoch || it.recoverer != prepared.draft.recoverer || it.recovererKeyDigest != prepared.recovererKeyDigest || it.keyDigest != prepared.draft.keyDigest) throw MemberFailure.ScopeMismatch
        }
    }
    suspend fun createRequest(requesterPublicKey: String): MemberRecoveryRequest {
        if (!MemberRecoveryWire.key(requesterPublicKey)) throw MemberFailure.Malformed; val body = buildJsonObject { put("requesterPublicKey", JsonPrimitive(requesterPublicKey)) }.toString().toByteArray()
        val (reply, session) = post("/member/recovery/requests", body, expectedStatus = 201); return MemberRecoveryWire.request(MemberRecoveryWire.objectOf(reply.body), session.household).also { if (it.owner != session.household || it.requesterPublicKey != requesterPublicKey) throw MemberFailure.ScopeMismatch }
    }
    suspend fun requests(): List<MemberRecoveryRequest> { val (reply, session) = get("/member/recovery/requests"); return MemberRecoveryWire.requests(reply.body, session.household) }
    suspend fun request(id: String): MemberRecoveryRequest {
        canonicalId(id); val (reply, session) = get("/member/recovery/requests/$id"); return MemberRecoveryWire.request(MemberRecoveryWire.objectOf(reply.body), session.household).also { if (it.id != id) throw MemberFailure.ScopeMismatch }
    }
    suspend fun prepareApproval(id: String, release: String): PreparedMemberRecoveryApproval {
        canonicalId(id); if (!MemberRecoveryWire.b64(release, 96..2048)) throw MemberFailure.Malformed
        val body = buildJsonObject { put("release", JsonPrimitive(release)) }.toString().toByteArray(); val (reply, session) = post("/member/recovery/requests/$id/prepare", body)
        val text = reply.body.toString(Charsets.UTF_8); val root = MemberRecoveryWire.objectOf(reply.body)
        if (root.keys != setOf("profile", "request", "release", "id", "expiresAt", "publicKey") || root["profile"] != JsonPrimitive("atarasy.member-recovery-approval-review.1") || root["release"] != JsonPrimitive(release)) throw MemberFailure.ScopeMismatch
        val request = MemberRecoveryWire.request(root.getValue("request"), session.household); if (request.id != id || request.recoverer != session.household) throw MemberFailure.ScopeMismatch
        return PreparedMemberRecoveryApproval(request, release, MemberRecoveryWire.ceremony(text, environment, now()), session.id)
    }
    suspend fun approve(prepared: PreparedMemberRecoveryApproval, assertionJson: String): MemberRecoveryRequest {
        active(prepared.sessionId); val assertion = MemberRecoveryWire.assertion(assertionJson, prepared.ceremony, environment, acceptedOrigins)
        val body = buildJsonObject { put("preparation", JsonPrimitive(prepared.ceremony.id)); put("release", JsonPrimitive(prepared.release)); put("assertion", assertion) }.toString().toByteArray()
        val (reply, session) = post("/member/recovery/requests/${prepared.request.id}/approve", body)
        return MemberRecoveryWire.request(MemberRecoveryWire.objectOf(reply.body), session.household).also { if (it.id != prepared.request.id || it.state !in setOf("approved", "completed")) throw MemberFailure.ScopeMismatch }
    }
    suspend fun log(): MemberRecoveryLog { val (reply, session) = get("/member/recovery/log"); return MemberRecoveryWire.log(reply.body, session.household) }
    private suspend fun active(id: String) { if (sessions.activeInfo().id != id) throw MemberFailure.ScopeMismatch }
    private suspend fun get(path: String) = sessions.readWithSession(path).also { json(it.first, 200) }
    private suspend fun post(path: String, body: ByteArray, expectedStatus: Int = 200) = sessions.readWithSession(path, body = body).also { json(it.first, expectedStatus) }
    private fun json(reply: MemberHttpResponse, status: Int) { if (reply.status != status) throw MemberFailure.Http(reply.status); if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed }
    private fun canonicalId(id: String) { try { require(UUID.fromString(id).toString() == id) } catch (_: Exception) { throw MemberFailure.Malformed } }
}
