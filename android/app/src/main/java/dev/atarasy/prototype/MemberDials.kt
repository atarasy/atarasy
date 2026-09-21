package dev.atarasy.prototype

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

data class MemberMandateChange(
    val id: String,
    val before: Mandate,
    val mandate: Mandate,
    val requiredSigners: List<String>,
    val signedBy: List<String>,
    val state: String,
    val createdAt: Long,
    val updatedAt: Long,
)

data class PreparedMemberMandateChange(
    val change: MemberMandateChange,
    val publicKey: JsonObject,
    val publicKeyJson: String,
    val sessionId: String,
    val credentialId: String,
    val expiresAt: Long,
)

object MemberDialsCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val mandateKeys = "id household ceiling_out_of_network ceiling_daily cooling_seconds co_signers lapses_at version".split(' ').toSet()
    private val changeKeys = setOf("id", "before", "mandate", "requiredSigners", "signedBy", "state", "createdAt", "updatedAt")

    fun mandate(element: JsonElement): Mandate = malformed {
        val row = element.jsonObject; require(row.keys == mandateKeys)
        Mandate(
            row.string("id"), row.string("household"), row.number("ceiling_out_of_network"), row.optionalNumber("ceiling_daily"),
            row.optionalNumber("cooling_seconds"), row.getValue("co_signers").jsonArray.map { it.jsonPrimitive.let { p -> require(p.isString); p.content } },
            row.number("lapses_at"), row.number("version"),
        ).also { Canonical.validateMandate(it); require(it.coSigners.distinct().size == it.coSigners.size && it.coSigners.all { signer -> signer.isNotEmpty() && '\n' !in signer && '\r' !in signer }) }
    }
    fun mandateJson(value: Mandate): JsonObject = buildJsonObject {
        put("id", JsonPrimitive(value.id)); put("household", JsonPrimitive(value.household)); put("ceiling_out_of_network", JsonPrimitive(value.ceilingOutOfNetwork))
        put("ceiling_daily", value.ceilingDaily?.let(::JsonPrimitive) ?: JsonNull); put("cooling_seconds", value.coolingSeconds?.let(::JsonPrimitive) ?: JsonNull)
        put("co_signers", buildJsonArray { value.coSigners.forEach { add(JsonPrimitive(it)) } }); put("lapses_at", JsonPrimitive(value.lapsesAt)); put("version", JsonPrimitive(value.version))
    }
    fun effective(bytes: ByteArray, household: String): List<Mandate> = list(bytes, "mandates") { value ->
        val mandate = mandate(value); require(mandate.household == household && mandate.id.startsWith("$household.")) { "scope" }; mandate
    }
    fun changes(bytes: ByteArray, session: MemberSessionInfo): List<MemberMandateChange> = list(bytes, "changes") { change(it, session) }
    fun change(element: JsonElement, session: MemberSessionInfo): MemberMandateChange = malformed {
        val row = element.jsonObject; require(row.keys == changeKeys)
        val value = MemberMandateChange(
            row.string("id"), mandate(row.getValue("before")), mandate(row.getValue("mandate")),
            row.strings("requiredSigners"), row.strings("signedBy"), row.string("state"), row.number("createdAt"), row.number("updatedAt"),
        )
        require(UUID.fromString(value.id).toString() == value.id && value.before.id == value.mandate.id && value.before.household == value.mandate.household)
        require(value.mandate.version == value.before.version + 1 && value.state in setOf("pending", "effective", "cancelled", "stale") && value.updatedAt >= value.createdAt)
        require(value.requiredSigners.distinct().size == value.requiredSigners.size && value.signedBy.distinct().size == value.signedBy.size && value.signedBy.all { it in value.requiredSigners })
        require(value.mandate.household in value.requiredSigners && (value.mandate.household == session.household || session.household in value.requiredSigners)) { "scope" }
        value
    }
    fun prepared(bytes: ByteArray, environment: MemberEnvironment, session: MemberSessionInfo, now: Long): PreparedMemberMandateChange = malformed {
        val text = bytes.toString(Charsets.UTF_8); val root = json.parseToJsonElement(text).jsonObject
        require(root.keys == changeKeys + "publicKey")
        val change = change(JsonObject(root - "publicKey"), session); require(change.state == "pending")
        val publicKey = root.getValue("publicKey").jsonObject; require(publicKey.keys == setOf("challenge", "rpId", "userVerification", "allowCredentials"))
        require(publicKey.string("challenge") == Canonical.challenge(Canonical.mandate(change.mandate, environment.relyingPartyId))) { "scope" }
        require(publicKey.string("rpId") == environment.relyingPartyId && publicKey.string("userVerification") == "required")
        val allowed = publicKey.getValue("allowCredentials").jsonArray; require(allowed.size == 1)
        val credential = allowed.single().jsonObject; require(credential.keys == setOf("type", "id") && credential.string("type") == "public-key")
        val rawPublicKey = MemberAuthenticationWire.rawObjectMember(text, "publicKey") ?: error("publicKey")
        PreparedMemberMandateChange(change, publicKey, rawPublicKey, session.id, credential.string("id"), minOf(session.expiresAt, now + 300_000))
    }
    private fun <T> list(bytes: ByteArray, key: String, decode: (JsonElement) -> T): List<T> = malformed {
        val root = json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject; require(root.keys == setOf(key))
        val values = root.getValue(key).jsonArray.map(decode); require(values.size <= 100)
        val ids = values.map { when (it) { is Mandate -> it.id; is MemberMandateChange -> it.id; else -> error("row") } }; require(ids.distinct().size == ids.size); values
    }
    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun JsonObject.optionalNumber(key: String) = getValue(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(!it.isString); it.long }.also { require(it == null || it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun JsonObject.strings(key: String) = getValue(key).jsonArray.map { it.jsonPrimitive.let { p -> require(p.isString); p.content } }
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: MemberFailure.ScopeMismatch) { throw e }
    catch (e: IllegalArgumentException) { if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed }
    catch (_: Exception) { throw MemberFailure.Malformed }
}

class MemberDials(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
    private val now: () -> Long = System::currentTimeMillis,
    private val acceptedOrigins: Set<String> = setOf(environment.origin),
) {
    private var held: PreparedMemberMandateChange? = null
    suspend fun effective(): List<Mandate> { val (reply, session) = sessions.readWithSession("/member/mandates/effective"); json200(reply); return MemberDialsCodec.effective(reply.body, session.household) }
    suspend fun changes(): List<MemberMandateChange> { val (reply, session) = sessions.readWithSession("/member/mandates/changes"); json200(reply); return MemberDialsCodec.changes(reply.body, session) }
    suspend fun prepare(mandate: Mandate): PreparedMemberMandateChange {
        held = null; val active = sessions.activeInfo(); val body = buildJsonObject { put("mandate", MemberDialsCodec.mandateJson(mandate)) }.toString().toByteArray()
        val (reply, current) = sessions.readWithSession("/member/mandates/changes", body = body); if (current != active) throw MemberFailure.Superseded
        if (reply.status != 201) throw MemberFailure.Http(reply.status); json(reply)
        val value = MemberDialsCodec.prepared(reply.body, environment, current, now())
        if (value.change.mandate != mandate || value.change.before.household != current.household) throw MemberFailure.ScopeMismatch
        held = value; return value
    }
    suspend fun prepareSignature(id: String): PreparedMemberMandateChange {
        held = null; canonicalId(id); val (reply, session) = sessions.readWithSession("/member/mandates/changes/$id/prepare"); json200(reply)
        val value = MemberDialsCodec.prepared(reply.body, environment, session, now())
        if (value.change.id != id || session.household !in value.change.requiredSigners) throw MemberFailure.ScopeMismatch
        held = value; return value
    }
    suspend fun submit(prepared: PreparedMemberMandateChange, assertionJson: String): MemberMandateChange {
        val retained = held
        if (retained != prepared || retained.sessionId != sessions.activeInfo().id || retained.expiresAt <= now()) throw MemberFailure.ScopeMismatch
        val assertion = try { Json.parseToJsonElement(assertionJson).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        val response = assertion["response"]?.jsonObject ?: throw MemberFailure.Malformed
        if (assertion.stringOrNull("id") != retained.credentialId) throw MemberFailure.ScopeMismatch
        val encodedClient = response.stringOrNull("clientDataJSON") ?: throw MemberFailure.Malformed
        val clientBytes = decode64(encodedClient); val client = try { Json.parseToJsonElement(clientBytes.toString(Charsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.ScopeMismatch }
        if (client.stringOrNull("type") != "webauthn.get" || client.stringOrNull("origin") !in acceptedOrigins || client.containsKey("topOrigin") ||
            (client.containsKey("crossOrigin") && client["crossOrigin"] != JsonPrimitive(false)) ||
            client.stringOrNull("challenge") != Canonical.challenge(Canonical.mandate(retained.change.mandate, environment.relyingPartyId))) throw MemberFailure.ScopeMismatch
        fun standard(key: String) = Base64.getEncoder().encodeToString(decode64(response.stringOrNull(key) ?: throw MemberFailure.Malformed))
        val body = buildJsonObject { put("assertion", buildJsonObject {
            put("client_data_json", JsonPrimitive(standard("clientDataJSON"))); put("authenticator_data", JsonPrimitive(standard("authenticatorData"))); put("signature", JsonPrimitive(standard("signature")))
        }) }.toString().toByteArray()
        if (body.size > 16_384) throw MemberFailure.Malformed
        held = null
        return try {
            val (reply, session) = sessions.readWithSession("/member/mandates/changes/${retained.change.id}/submit", body = body); json200(reply)
            MemberDialsCodec.change(Json.parseToJsonElement(reply.body.toString(Charsets.UTF_8)), session).also { if (it.id != retained.change.id) throw MemberFailure.ScopeMismatch }
        } catch (_: Exception) { throw MemberFailure.Unavailable }
    }
    suspend fun cancel(id: String): MemberMandateChange {
        canonicalId(id); val (reply, session) = sessions.readWithSession("/member/mandates/changes/$id/cancel", body = "{}".toByteArray()); json200(reply)
        return MemberDialsCodec.change(Json.parseToJsonElement(reply.body.toString(Charsets.UTF_8)), session).also { if (it.id != id || it.state != "cancelled") throw MemberFailure.ScopeMismatch }
    }
    private fun decode64(value: String): ByteArray = try { Base64.getUrlDecoder().decode(value).also { if (it.isEmpty() || it.size > 8192) throw MemberFailure.Malformed } } catch (e: MemberFailure) { throw e } catch (_: Exception) { throw MemberFailure.Malformed }
    private fun JsonObject.stringOrNull(key: String) = get(key)?.jsonPrimitive?.let { if (it.isString) it.content else null }
    private fun canonicalId(id: String) { try { require(UUID.fromString(id).toString() == id) } catch (_: Exception) { throw MemberFailure.Malformed } }
    private fun json200(reply: MemberHttpResponse) { if (reply.status != 200) throw MemberFailure.Http(reply.status); json(reply) }
    private fun json(reply: MemberHttpResponse) { if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed }
}
