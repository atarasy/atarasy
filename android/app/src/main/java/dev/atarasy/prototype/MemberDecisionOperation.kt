package dev.atarasy.prototype

import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.Base64
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

const val MEMBER_DECISION_PROFILE = "atarasy.member-decision-authorisation.1"

data class MemberPreparedDecision(
    val profile: String,
    val operationId: String,
    val requestDigest: String,
    val reviewedRevision: String,
    val expiresAt: Long,
    val canonical: String,
    val review: JsonObject,
    val operationState: String,
    val publicKey: JsonObject,
    val publicKeyJson: String,
    val challenge: String,
    val credentialId: String,
)
data class FrozenMemberDecision(
    val approval: MemberApproval,
    val mandate: Mandate,
    val decisions: List<Decision>,
    val goods: Long,
    val carriage: Long,
    val total: Long,
)

object MemberDecisionWire {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val preparedKeys = "profile operationID requestDigest reviewedRevision expiresAt canonical review operationState publicKey".split(' ').toSet()

    fun prepareBody(local: PreparedMemberDecision): ByteArray = buildJsonObject {
        put("offer", JsonPrimitive(local.detail.id))
        put("decisions", buildJsonArray { local.decisions.forEach { decision -> add(buildJsonObject {
            put("candidate", JsonPrimitive(decision.candidate)); put("valence", JsonPrimitive(decision.valence)); decision.keptAs?.let { put("kept_as", JsonPrimitive(it)) }
        }) } })
    }.toString().toByteArray()

    fun prepared(bytes: ByteArray, environment: MemberEnvironment, expectedCanonical: String): MemberPreparedDecision = malformed {
        val text = bytes.toString(StandardCharsets.UTF_8); val root = json.parseToJsonElement(text).jsonObject
        require(root.keys == preparedKeys)
        fun string(key: String) = root.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        val profile = string("profile"); val operationId = string("operationID"); val requestDigest = string("requestDigest"); val revision = string("reviewedRevision")
        val expiry = root.getValue("expiresAt").jsonPrimitive.let { require(!it.isString); it.long }; val canonical = string("canonical"); val state = string("operationState")
        val publicKey = root.getValue("publicKey").jsonObject; val review = root.getValue("review").jsonObject
        require(profile == MEMBER_DECISION_PROFILE && UUID.fromString(operationId).toString() == operationId)
        require(Regex("^[a-f0-9]{64}$").matches(requestDigest) && Regex("^[a-f0-9]{64}$").matches(revision))
        require(expiry in 0..Canonical.MAXIMUM_INTEGER && canonical == expectedCanonical && state in setOf("prepared", "dispatching", "uncertain", "committed", "cancelled", "refused"))
        require(publicKey.keys == setOf("challenge", "rpId", "userVerification", "allowCredentials"))
        fun pkString(key: String) = publicKey.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        val challenge = pkString("challenge"); require(Regex("^[A-Za-z0-9_-]{43}$").matches(challenge))
        require(pkString("rpId") == environment.relyingPartyId && pkString("userVerification") == "required")
        val allowed = publicKey.getValue("allowCredentials").jsonArray; require(allowed.size == 1)
        val credential = allowed.single().jsonObject; require(credential.keys == setOf("type", "id") && credential["type"] == JsonPrimitive("public-key"))
        val credentialId = credential.getValue("id").jsonPrimitive.let { require(it.isString && it.content.isNotEmpty()); it.content }
        val scope = JsonArray(listOf(JsonPrimitive(1), JsonPrimitive(environment.name), JsonPrimitive(environment.origin), JsonPrimitive(environment.relyingPartyId))).toString()
        val envelope = JsonArray(listOf(JsonPrimitive(profile), JsonPrimitive(scope), JsonPrimitive(operationId), JsonPrimitive(requestDigest), JsonPrimitive(revision))).toString()
        require(challenge == Canonical.challenge(envelope)) { "scope" }
        val raw = MemberAuthenticationWire.rawObjectMember(text, "publicKey") ?: error("publicKey")
        MemberPreparedDecision(profile, operationId, requestDigest, revision, expiry, canonical, review, state, publicKey, raw, challenge, credentialId)
    }

    fun freeze(value: MemberPreparedDecision, local: PreparedMemberDecision, now: Long): FrozenMemberDecision = malformed {
        val review = value.review; require(review.keys == setOf("approval", "mandate", "decisions", "goods", "carriage", "total"))
        val approval = MemberReviewCodec.approval(review.getValue("approval").toString().toByteArray(), local.detail)
        val mandate = mandate(review.getValue("mandate"), local.detail.mandate, local.detail.household)
        val decisions = review.getValue("decisions").jsonArray.map { element ->
            val row = element.jsonObject; val candidate = row.string("candidate"); val valence = row.string("valence")
            if (valence == "kept") { require(row.keys == setOf("candidate", "valence", "kept_as") && row.string("kept_as") == "self"); Decision(candidate, valence, "self") }
            else { require(valence == "returned" && row.keys == setOf("candidate", "valence")); Decision(candidate, valence) }
        }
        fun safe(key: String) = review.getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
        val goods = safe("goods"); val carriage = safe("carriage"); val total = safe("total")
        require(approval == local.approval && Canonical.decisions(local.detail.id, decisions) == local.canonical) { "scope" }
        require(goods == local.summary.goods && carriage == local.summary.carriage && total == local.summary.total) { "scope" }
        require(value.expiresAt > now && value.expiresAt <= local.session.expiresAt && value.expiresAt <= local.detail.expiresAt && value.expiresAt <= mandate.lapsesAt && value.expiresAt <= (approval.mandate.lapsesAt ?: Canonical.MAXIMUM_INTEGER)) { "scope" }
        FrozenMemberDecision(approval, mandate, decisions, goods, carriage, total)
    }

    private fun mandate(element: JsonElement, expectedId: String, household: String): Mandate {
        val row = element.jsonObject; require(row.keys == "ceiling_out_of_network ceiling_daily cooling_seconds co_signers lapses_at version id household".split(' ').toSet())
        fun string(key: String) = row.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        fun number(key: String) = row.getValue(key).jsonPrimitive.let { require(!it.isString); it.long }
        fun optional(key: String) = row.getValue(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(!it.isString); it.long }
        val value = Mandate(string("id"), string("household"), number("ceiling_out_of_network"), optional("ceiling_daily"), optional("cooling_seconds"), row.getValue("co_signers").jsonArray.map { it.jsonPrimitive.let { p -> require(p.isString); p.content } }, number("lapses_at"), number("version"))
        require(value.id == expectedId && value.household == household) { "scope" }; Canonical.validateMandate(value); require(value.version >= 1 && value.coSigners.all { it.isNotEmpty() }); return value
    }
    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: IllegalArgumentException) { if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed } catch (e: MemberFailure.ScopeMismatch) { throw e } catch (_: Exception) { throw MemberFailure.Malformed }
}

data class PreparedDecisionResult(val handle: MemberOperationHandle, val prepared: MemberPreparedDecision, val frozen: FrozenMemberDecision)
sealed interface MemberDecisionOutcome {
    data class Recorded(val detail: MemberOfferDetail) : MemberDecisionOutcome
    data class Pending(val state: String) : MemberDecisionOutcome
    data object Unresolved : MemberDecisionOutcome
}

class MemberDecisionOperations(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
    private val store: MemberOperationStore,
    private val now: () -> Long = System::currentTimeMillis,
    private val acceptedOrigins: Set<String> = setOf(environment.origin),
) {
    suspend fun prepare(local: PreparedMemberDecision): PreparedDecisionResult {
        val active = sessions.activeInfo()
        if (local.environment != environment || local.session != active || local.detail.household != active.household || local.detail.presenter !in active.presenters) throw MemberFailure.ScopeMismatch
        val (reply, current) = sessions.readWithSession("/member/decisions/prepare", body = MemberDecisionWire.prepareBody(local))
        if (current != active) throw MemberFailure.Superseded
        json200(reply)
        val prepared = MemberDecisionWire.prepared(reply.body, environment, local.canonical)
        val frozen = MemberDecisionWire.freeze(prepared, local, now())
        if (prepared.operationState != "prepared" || prepared.expiresAt <= now() || prepared.expiresAt > active.expiresAt) throw MemberFailure.Malformed
        val handle = MemberOperationHandle(prepared.operationId, MEMBER_DECISION_PROFILE, environment.name, environment.origin, active.id, active.household, local.detail.presenter, local.detail.id, local.canonical, prepared.expiresAt, prepared.requestDigest, prepared.reviewedRevision, prepared.challenge, prepared.credentialId, digitalTermsDigest = MemberDigitalTerms.digest(local.detail))
        try { store.save(handle); return PreparedDecisionResult(store.load(handle.id) ?: handle, prepared, frozen) } catch (_: Exception) { throw MemberFailure.Storage }
    }

    suspend fun review(handle: MemberOperationHandle): MemberPreparedDecision {
        scope(handle); val (reply, _) = sessions.readWithSession("/member/operations/${handle.id}"); json200(reply)
        val value = MemberDecisionWire.prepared(reply.body, environment, handle.canonical)
        if (value.operationId != handle.id || value.expiresAt != handle.expiresAt || value.requestDigest != handle.requestDigest || value.reviewedRevision != handle.reviewedRevision || value.challenge != handle.challenge || value.credentialId != handle.credentialId) throw MemberFailure.ScopeMismatch
        return value
    }

    suspend fun submit(handle: MemberOperationHandle, assertionJson: String): MemberDecisionOutcome {
        scope(handle)
        if (handle.expiresAt <= now() || handle.attempted || handle.digitalTermsDigest == null) throw MemberFailure.Expired
        val assertion = try { Json.parseToJsonElement(assertionJson).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        val id = assertion["id"]?.jsonPrimitive?.let { if (it.isString) it.content else null }
        val response = assertion["response"]?.jsonObject ?: throw MemberFailure.Malformed
        val clientData = response["clientDataJSON"]?.jsonPrimitive?.let { if (it.isString) it.content else null } ?: throw MemberFailure.Malformed
        val signature = response["signature"]?.jsonPrimitive?.let { if (it.isString) it.content else null } ?: throw MemberFailure.Malformed
        if (id != handle.credentialId || signature.isEmpty()) throw MemberFailure.ScopeMismatch
        val decoded = try { Base64.getUrlDecoder().decode(clientData) } catch (_: Exception) { throw MemberFailure.ScopeMismatch }
        val client = try { Json.parseToJsonElement(decoded.toString(StandardCharsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.ScopeMismatch }
        fun text(key: String) = client[key]?.jsonPrimitive?.let { if (it.isString) it.content else null }
        if (text("type") != "webauthn.get" || text("challenge") != handle.challenge || text("origin") !in acceptedOrigins || client.containsKey("topOrigin") ||
            (client.containsKey("crossOrigin") && client["crossOrigin"] != JsonPrimitive(false))) throw MemberFailure.ScopeMismatch
        val body = buildJsonObject { put("assertion", assertion) }.toString().toByteArray()
        if (body.size > 16_384) throw MemberFailure.Malformed
        store.claim(handle, signature)
        return try {
            val (reply, _) = sessions.readWithSession("/member/operations/${handle.id}/submit", body = body)
            json200(reply); decodeOutcome(reply.body, handle.claimed(signature))
        } catch (_: Exception) { MemberDecisionOutcome.Unresolved }
    }

    suspend fun outcome(handle: MemberOperationHandle): MemberDecisionOutcome = try {
        scope(handle); val (reply, _) = sessions.readWithSession("/member/operations/${handle.id}/outcome"); json200(reply); decodeOutcome(reply.body, handle)
    } catch (_: Exception) { MemberDecisionOutcome.Unresolved }

    internal fun decodeOutcome(bytes: ByteArray, handle: MemberOperationHandle): MemberDecisionOutcome {
        val root = try { Json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        if (root.keys != setOf("operationID", "operationState", "decision")) throw MemberFailure.Malformed
        fun string(key: String) = root.getValue(key).jsonPrimitive.let { if (!it.isString) throw MemberFailure.Malformed; it.content }
        if (string("operationID") != handle.id) throw MemberFailure.ScopeMismatch
        val state = string("operationState"); val decision = root.getValue("decision")
        if (state != "committed") {
            if (state !in setOf("prepared", "dispatching", "uncertain", "cancelled", "refused") || decision !== JsonNull) throw MemberFailure.Malformed
            return MemberDecisionOutcome.Pending(state)
        }
        val objectValue = decision.jsonObject.toMutableMap()
        val reminders = objectValue.remove("reminders_sent")?.jsonPrimitive?.let { if (it.isString) throw MemberFailure.Malformed; it.long } ?: throw MemberFailure.Malformed
        if (reminders !in 0..1) throw MemberFailure.Malformed
        val detail = MemberOfferCodec.detail(JsonObject(objectValue).toString().toByteArray(), handle.offer, handle.household, handle.presenter)
        val decidedAt = detail.decidedAt
        if (detail.binding != "digital" || detail.state !in setOf("decided", "settled") || decidedAt == null || decidedAt >= handle.expiresAt || MemberDigitalTerms.digest(detail) != handle.digitalTermsDigest) throw MemberFailure.ScopeMismatch
        if (detail.candidates.any { it.decidedAt != decidedAt || it.lineage != null || !((it.valence == "kept" && it.keptAs == "self") || (it.valence == "returned" && it.keptAs == null)) }) throw MemberFailure.ScopeMismatch
        val decisions = detail.candidates.map { Decision(it.id, it.valence, it.keptAs) }
        if (Canonical.decisions(detail.id, decisions) != handle.canonical) throw MemberFailure.ScopeMismatch
        return MemberDecisionOutcome.Recorded(detail)
    }
    private suspend fun scope(handle: MemberOperationHandle) { val active = sessions.activeInfo(); if (handle.operationProfile != MEMBER_DECISION_PROFILE || handle.environment != environment.name || handle.origin != environment.origin || handle.household != active.household || handle.presenter !in active.presenters) throw MemberFailure.ScopeMismatch }
    private fun json200(reply: MemberHttpResponse) { if (reply.status != 200) throw MemberFailure.Http(reply.status); if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed }
}

object MemberDigitalTerms {
    fun digest(detail: MemberOfferDetail): String = Canonical.digest(canonicalJson(detail))
    private fun canonicalJson(detail: MemberOfferDetail): String {
        fun nullable(value: String?) = value?.let(::JsonPrimitive) ?: JsonNull
        val candidates = detail.candidates.sortedBy { it.id }.map { c -> mapOf<String, JsonElement>(
            "category" to nullable(c.category), "givenBy" to nullable(c.givenBy), "id" to JsonPrimitive(c.id), "isExploration" to JsonPrimitive(c.isExploration),
            "maker" to JsonPrimitive(c.maker), "merchant" to JsonPrimitive(c.merchant), "predictedConversion" to (c.predictedConversion?.let(::JsonPrimitive) ?: JsonNull),
            "product" to JsonPrimitive(c.product), "quantity" to JsonPrimitive(c.quantity), "ships" to JsonPrimitive(c.ships), "unitPrice" to JsonPrimitive(c.unitPrice),
        ) }
        val disclosures = detail.disclosures.map { d -> mapOf<String, JsonElement>("items" to JsonArray(d.items.map { i -> sorted(mapOf("label" to JsonPrimitive(i.label), "value" to JsonPrimitive(i.value))) }), "merchant" to JsonPrimitive(d.merchant), "product" to nullable(d.product), "signature" to JsonPrimitive(d.signature), "version" to JsonPrimitive(d.version)) }
        val root = mapOf<String, JsonElement>(
            "binding" to JsonPrimitive(detail.binding), "candidates" to JsonArray(candidates.map(::sorted)), "configVersion" to JsonPrimitive(detail.configVersion),
            "disclosures" to JsonArray(disclosures.map(::sorted)), "expiresAt" to JsonPrimitive(detail.expiresAt), "explorationFloorMet" to JsonPrimitive(detail.explorationFloorMet),
            "giver" to nullable(detail.giver), "household" to JsonPrimitive(detail.household), "id" to JsonPrimitive(detail.id), "mandate" to JsonPrimitive(detail.mandate),
            "presentedAt" to (detail.presentedAt?.let(::JsonPrimitive) ?: JsonNull), "presenter" to JsonPrimitive(detail.presenter), "presenterAttested" to JsonPrimitive(detail.presenterAttested),
            "priceBand" to (detail.priceBand?.let { sorted(mapOf("max" to JsonPrimitive(it.max), "min" to JsonPrimitive(it.min))) } ?: JsonNull), "purpose" to JsonPrimitive(detail.purpose),
        )
        return sorted(root).toString()
    }
    private fun sorted(values: Map<String, JsonElement>) = JsonObject(values.toSortedMap())
}
