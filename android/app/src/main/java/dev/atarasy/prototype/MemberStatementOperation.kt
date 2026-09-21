package dev.atarasy.prototype

import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

const val MEMBER_STATEMENT_PROFILE = "atarasy.member-statement-authorisation.1"

data class PreparedMemberStatement(
    val environment: MemberEnvironment,
    val sessionId: String,
    val sessionExpiresAt: Long,
    val household: String,
    val presenter: String,
    val offer: String,
    val canonical: String,
    val challenge: String,
    val goodsCharged: Long,
    val disputedGoods: Long,
    val carriage: Long,
    val disputed: List<String>,
    val statement: MemberStatement,
) {
    companion object {
        fun create(environment: MemberEnvironment, session: MemberSessionInfo, detail: MemberOfferDetail, statement: MemberStatement, disputed: List<String>, now: Long): PreparedMemberStatement {
            if (now < 0 || session.expiresAt <= now) throw MemberFailure.Expired
            if (session.household != detail.household || detail.presenter !in session.presenters || statement.offer != detail.id || statement.household != detail.household || statement.expiresAt != detail.expiresAt) throw MemberFailure.ScopeMismatch
            if (detail.binding != "physical" || detail.giver != null || detail.state !in setOf("decided", "expired") || detail.candidates.any { it.valence == "offered" } ||
                (detail.candidates.none { it.valence == "consumed" } && statement.lines.none { it.valence == "lost" }) || statement.carriage == null || statement.disclosures != detail.disclosures) throw MemberFailure.Malformed
            if (disputed.distinct().size != disputed.size || disputed.any { id -> detail.candidates.none { it.id == id && it.valence == "consumed" } && statement.lines.none { it.candidate == id && it.valence == "lost" } }) throw MemberFailure.Malformed
            val disputedSet = disputed.toSet(); val canonicalLines = mutableListOf<StatementLine>(); var charged = 0L; var contested = 0L
            detail.candidates.forEach { candidate ->
                if (candidate.valence == "returned") return@forEach
                val product = try { Math.multiplyExact(candidate.quantity, candidate.unitPrice) } catch (_: Exception) { throw MemberFailure.Malformed }
                if (product !in 0..Canonical.MAXIMUM_INTEGER) throw MemberFailure.Malformed
                val amount = if (candidate.givenBy != null && candidate.valence != "lost") 0L else product
                val isDisputed = candidate.id in disputedSet
                if (candidate.valence == "lost") {
                    statement.lines.firstOrNull { it.candidate == candidate.id }?.let { line ->
                        if (line.valence != "lost" || line.amount != 0L) throw MemberFailure.Malformed
                        canonicalLines += StatementLine(candidate.id, "lost", 0, isDisputed)
                    }
                } else {
                    val line = statement.lines.singleOrNull { it.candidate == candidate.id } ?: throw MemberFailure.Malformed
                    if (line.product != candidate.product || line.merchant != candidate.merchant || line.maker != candidate.maker || line.ships != candidate.ships || line.givenBy != candidate.givenBy || line.quantity != candidate.quantity || line.unitPrice != candidate.unitPrice || line.valence != candidate.valence || line.amount != amount) throw MemberFailure.Malformed
                    canonicalLines += StatementLine(candidate.id, candidate.valence, amount, isDisputed)
                }
                if (candidate.valence == "consumed") {
                    if (isDisputed) contested = add(contested, amount) else charged = add(charged, amount)
                } else if (candidate.valence in setOf("kept", "defaulted")) charged = add(charged, amount)
            }
            if (statement.lines.size != canonicalLines.size) throw MemberFailure.Malformed
            val unsigned = canonicalLines.map { it.copy(disputed = false) }
            if (statement.challenge != Canonical.challenge(Canonical.statement(detail.id, statement.carriage, unsigned))) throw MemberFailure.Malformed
            val canonical = Canonical.statement(detail.id, statement.carriage, canonicalLines)
            return PreparedMemberStatement(environment, session.id, session.expiresAt, detail.household, detail.presenter, detail.id, canonical, Canonical.challenge(canonical), charged, contested, statement.carriage, disputed, statement)
        }
        private fun add(total: Long, amount: Long): Long { if (amount < 0 || total > Canonical.MAXIMUM_INTEGER - amount) throw MemberFailure.Malformed; return total + amount }
    }
}

data class MemberPreparedStatement(
    val operationId: String, val requestDigest: String, val reviewedRevision: String, val expiresAt: Long, val canonical: String,
    val review: JsonObject, val operationState: String, val publicKey: JsonObject, val publicKeyJson: String, val challenge: String, val credentialId: String,
)
sealed interface MemberStatementOutcome {
    data class Committed(val receipt: ProtocolSettlement) : MemberStatementOutcome
    data class SettledElsewhere(val receipt: ProtocolSettlement) : MemberStatementOutcome
    data class Pending(val state: String) : MemberStatementOutcome
    data object Unresolved : MemberStatementOutcome
}

object MemberStatementWire {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    fun prepareBody(local: PreparedMemberStatement) = buildJsonObject {
        put("offer", JsonPrimitive(local.offer)); put("disputed", buildJsonArray { local.disputed.forEach { add(JsonPrimitive(it)) } })
    }.toString().toByteArray()

    fun prepared(bytes: ByteArray, environment: MemberEnvironment, local: PreparedMemberStatement, detail: MemberOfferDetail): MemberPreparedStatement = malformed {
        val text = bytes.toString(StandardCharsets.UTF_8); val root = json.parseToJsonElement(text).jsonObject
        require(root.keys == "profile operationID requestDigest reviewedRevision expiresAt canonical review operationState publicKey authorisation".split(' ').toSet())
        fun string(key: String) = root.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        require(string("profile") == MEMBER_STATEMENT_PROFILE && string("canonical") == local.canonical)
        val id = string("operationID"); require(UUID.fromString(id).toString() == id)
        val digest = string("requestDigest"); val revision = string("reviewedRevision"); require(listOf(digest, revision).all { Regex("^[a-f0-9]{64}$").matches(it) })
        val expiry = root.getValue("expiresAt").jsonPrimitive.let { require(!it.isString); it.long }; require(expiry in 0..Canonical.MAXIMUM_INTEGER)
        val state = string("operationState"); require(state in setOf("prepared", "dispatching", "uncertain", "committed", "cancelled", "refused") && string("authorisation") in setOf("prepared", "verified"))
        val review = root.getValue("review").jsonObject; require(review.keys == setOf("statement", "mandate", "disputed"))
        val statementObject = review.getValue("statement").jsonObject
        require(statementObject.keys == setOf("offer", "household", "expires_at", "lines", "disclosures", "carriage"))
        val statement = MemberReviewCodec.statement(JsonObject(statementObject + ("challenge" to JsonPrimitive(local.statement.challenge))).toString().toByteArray(), detail)
        require(statement.offer == local.offer && statement.household == local.household && statement.carriage == local.carriage)
        val disputed = review.getValue("disputed").jsonArray.map { it.jsonPrimitive.let { p -> require(p.isString); p.content } }; require(disputed == local.disputed)
        val lines = statement.lines.map { StatementLine(it.candidate, it.valence, it.amount, it.candidate in disputed) }
        require(Canonical.statement(local.offer, local.carriage, lines) == local.canonical) { "scope" }
        val mandate = mandate(review.getValue("mandate").jsonObject, detail.mandate, local.household)
        val publicKey = root.getValue("publicKey").jsonObject; require(publicKey.keys == setOf("challenge", "rpId", "userVerification", "allowCredentials"))
        fun pk(key: String) = publicKey.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        require(pk("rpId") == environment.relyingPartyId && pk("userVerification") == "required")
        val credential = publicKey.getValue("allowCredentials").jsonArray.single().jsonObject; require(credential.keys == setOf("type", "id") && credential["type"] == JsonPrimitive("public-key"))
        val credentialId = credential.getValue("id").jsonPrimitive.let { require(it.isString && it.content.isNotEmpty()); it.content }
        val challenge = pk("challenge"); val scope = JsonArray(listOf(JsonPrimitive(1), JsonPrimitive(environment.name), JsonPrimitive(environment.origin), JsonPrimitive(environment.relyingPartyId))).toString()
        val envelope = JsonArray(listOf(JsonPrimitive(MEMBER_STATEMENT_PROFILE), JsonPrimitive(scope), JsonPrimitive(id), JsonPrimitive(digest), JsonPrimitive(revision))).toString()
        require(challenge == Canonical.challenge(envelope)) { "scope" }
        require(expiry <= mandate.lapsesAt) { "scope" }
        MemberPreparedStatement(id, digest, revision, expiry, local.canonical, review, state, publicKey, MemberAuthenticationWire.rawObjectMember(text, "publicKey") ?: error("publicKey"), challenge, credentialId)
    }
    private fun mandate(row: JsonObject, expectedId: String, household: String): Mandate {
        require(row.keys == "id household ceiling_out_of_network ceiling_daily cooling_seconds co_signers lapses_at version".split(' ').toSet())
        fun string(key: String) = row.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        fun number(key: String) = row.getValue(key).jsonPrimitive.let { require(!it.isString); it.long }
        fun optional(key: String) = row.getValue(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(!it.isString); it.long }
        val coSigners = row.getValue("co_signers").jsonArray.map { it.jsonPrimitive.let { p -> require(p.isString); p.content } }
        val value = Mandate(string("id"), string("household"), number("ceiling_out_of_network"), optional("ceiling_daily"), optional("cooling_seconds"), coSigners, number("lapses_at"), number("version"))
        require(value.id == expectedId && value.household == household) { "scope" }; require(coSigners.distinct().size == coSigners.size && coSigners.all { it.isNotEmpty() }); Canonical.validateMandate(value); return value
    }
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: IllegalArgumentException) { if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed } catch (e: MemberFailure.ScopeMismatch) { throw e } catch (_: Exception) { throw MemberFailure.Malformed }
}

class MemberStatementOperations(
    private val environment: MemberEnvironment, private val sessions: MemberSessionClient, private val store: MemberOperationStore,
    private val now: () -> Long = System::currentTimeMillis, private val acceptedOrigins: Set<String> = setOf(environment.origin),
) {
    suspend fun prepare(local: PreparedMemberStatement, detail: MemberOfferDetail): Pair<MemberOperationHandle, MemberPreparedStatement> {
        val active = sessions.activeInfo(); if (local.environment != environment || local.sessionId != active.id || local.household != active.household || local.presenter !in active.presenters) throw MemberFailure.ScopeMismatch
        val (reply, current) = sessions.readWithSession("/member/statements/prepare", body = MemberStatementWire.prepareBody(local)); if (current != active) throw MemberFailure.Superseded; json200(reply)
        val prepared = MemberStatementWire.prepared(reply.body, environment, local, detail)
        if (prepared.operationState != "prepared" || prepared.expiresAt <= now() || prepared.expiresAt > active.expiresAt) throw MemberFailure.Expired
        val handle = MemberOperationHandle(prepared.operationId, MEMBER_STATEMENT_PROFILE, environment.name, environment.origin, active.id, active.household, local.presenter, local.offer, local.canonical, prepared.expiresAt, prepared.requestDigest, prepared.reviewedRevision, prepared.challenge, prepared.credentialId)
        try { store.save(handle); return (store.load(handle.id) ?: handle) to prepared } catch (_: Exception) { throw MemberFailure.Storage }
    }
    suspend fun review(handle: MemberOperationHandle, local: PreparedMemberStatement, detail: MemberOfferDetail): MemberPreparedStatement {
        scope(handle); val (reply, _) = sessions.readWithSession("/member/operations/${handle.id}"); json200(reply)
        val value = MemberStatementWire.prepared(reply.body, environment, local, detail)
        if (value.operationId != handle.id || value.expiresAt != handle.expiresAt || value.requestDigest != handle.requestDigest || value.reviewedRevision != handle.reviewedRevision || value.challenge != handle.challenge || value.credentialId != handle.credentialId) throw MemberFailure.ScopeMismatch
        return value
    }
    suspend fun submit(handle: MemberOperationHandle, assertionJson: String): MemberStatementOutcome {
        scope(handle); if (handle.expiresAt <= now() || handle.attempted) throw MemberFailure.Expired
        val assertion = try { Json.parseToJsonElement(assertionJson).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        val response = assertion["response"]?.jsonObject ?: throw MemberFailure.Malformed
        val id = assertion["id"]?.jsonPrimitive?.let { if (it.isString) it.content else null }; val encoded = response["clientDataJSON"]?.jsonPrimitive?.let { if (it.isString) it.content else null }; val signature = response["signature"]?.jsonPrimitive?.let { if (it.isString) it.content else null }
        if (id != handle.credentialId || encoded == null || signature.isNullOrEmpty()) throw MemberFailure.ScopeMismatch
        val client = try { Json.parseToJsonElement(Base64.getUrlDecoder().decode(encoded).toString(StandardCharsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.ScopeMismatch }
        fun text(key: String) = client[key]?.jsonPrimitive?.let { if (it.isString) it.content else null }
        if (text("type") != "webauthn.get" || text("challenge") != handle.challenge || text("origin") !in acceptedOrigins || client.containsKey("topOrigin") || (client.containsKey("crossOrigin") && client["crossOrigin"] != JsonPrimitive(false))) throw MemberFailure.ScopeMismatch
        val body = buildJsonObject { put("assertion", assertion) }.toString().toByteArray(); if (body.size > 16_384) throw MemberFailure.Malformed
        store.claim(handle, signature)
        return try { val (reply, _) = sessions.readWithSession("/member/operations/${handle.id}/submit", body = body); json200(reply); decodeOutcome(reply.body, handle.claimed(signature)) } catch (_: Exception) { MemberStatementOutcome.Unresolved }
    }
    suspend fun outcome(handle: MemberOperationHandle): MemberStatementOutcome = try { scope(handle); val (reply, _) = sessions.readWithSession("/member/operations/${handle.id}/outcome"); json200(reply); decodeOutcome(reply.body, handle) } catch (_: Exception) { MemberStatementOutcome.Unresolved }
    internal fun decodeOutcome(bytes: ByteArray, handle: MemberOperationHandle): MemberStatementOutcome {
        val root = try { Json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        if (root.keys != setOf("operationID", "operationState", "receipt") || root["operationID"] != JsonPrimitive(handle.id)) throw MemberFailure.ScopeMismatch
        val state = root.getValue("operationState").jsonPrimitive.let { if (!it.isString) throw MemberFailure.Malformed; it.content }; val receiptJson = root.getValue("receipt")
        if (state != "committed") { if (state !in setOf("prepared", "dispatching", "uncertain", "cancelled", "refused") || receiptJson !== JsonNull) throw MemberFailure.Malformed; return MemberStatementOutcome.Pending(state) }
        val receipt = MemberSettlementCodec.decode(receiptJson.toString().toByteArray(), handle.offer)
        if (receipt.payer != handle.household || receipt.signedBy != handle.presenter || receipt.signedAs != "agent") throw MemberFailure.ScopeMismatch
        val parts = handle.canonical.split('\n'); if (parts.size < 3) throw MemberFailure.Malformed; val carriage = parts[2].toLongOrNull() ?: throw MemberFailure.Malformed
        val signedLost = parts.drop(3).mapNotNull { line -> line.split(':').takeIf { it.size == 4 && it[1] == "lost" }?.get(0) }.toSet()
        if (receipt.lines.any { it.valence == "lost" && it.disputed && it.candidate !in signedLost }) throw MemberFailure.ScopeMismatch
        val lines = receipt.lines.mapNotNull { line -> if (line.valence == "lost") { if (line.candidate in signedLost) StatementLine(line.candidate, "lost", 0, line.disputed) else null } else StatementLine(line.candidate, line.valence, line.amount, line.disputed) }
        if (Canonical.statement(handle.offer, carriage, lines) != handle.canonical) throw MemberFailure.ScopeMismatch
        if (!handle.attempted || handle.confirmationFingerprint == null || receipt.confirmation == null || Canonical.digest(receipt.confirmation) != handle.confirmationFingerprint) return MemberStatementOutcome.SettledElsewhere(receipt)
        return MemberStatementOutcome.Committed(receipt)
    }
    private suspend fun scope(handle: MemberOperationHandle) { val active = sessions.activeInfo(); if (handle.operationProfile != MEMBER_STATEMENT_PROFILE || handle.environment != environment.name || handle.origin != environment.origin || handle.household != active.household || handle.presenter !in active.presenters) throw MemberFailure.ScopeMismatch }
    private fun json200(reply: MemberHttpResponse) { if (reply.status != 200) throw MemberFailure.Http(reply.status); if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed }
}
