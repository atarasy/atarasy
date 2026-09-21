package dev.atarasy.prototype

import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

data class MemberPermission(
    val id: String,
    val kind: String,
    val resultForm: String?,
    val grantee: String,
    val scope: List<String>,
    val purpose: String,
    val grantedAt: Long,
    val expiresAt: Long,
    val askedFrom: String,
    val revokedAt: Long?,
) {
    fun sameGrant(other: MemberPermission) = copy(revokedAt = other.revokedAt) == other
}

data class MemberPermissionList(val household: String, val checkedAt: Long, val permissions: List<MemberPermission>)
data class MemberPermissionRequester(val id: String, val name: String)
data class MemberPermissionField(val id: String, val label: String)
data class MemberPermissionTerms(
    val profile: String,
    val requestId: String,
    val household: String,
    val action: String,
    val requester: MemberPermissionRequester,
    val purpose: String,
    val fields: List<MemberPermissionField>,
    val createdAt: Long,
    val reviewExpiresAt: Long,
    val accessExpiresAt: Long,
) {
    fun canonical(): String {
        fun quote(value: String) = JsonPrimitive(value).toString()
        return "{\"profile\":${quote(profile)},\"requestID\":${quote(requestId)},\"household\":${quote(household)},\"action\":${quote(action)}," +
            "\"requester\":{\"id\":${quote(requester.id)},\"name\":${quote(requester.name)}},\"purpose\":${quote(purpose)}," +
            "\"fields\":[${fields.joinToString(",") { "{\"id\":${quote(it.id)},\"label\":${quote(it.label)}}" }}]," +
            "\"createdAt\":$createdAt,\"reviewExpiresAt\":$reviewExpiresAt,\"accessExpiresAt\":$accessExpiresAt}"
    }
}

data class MemberPermissionRequest(
    val terms: MemberPermissionTerms,
    val digest: String,
    val state: String,
    val decidedAt: Long?,
    val permission: MemberPermission?,
) {
    val id get() = terms.requestId
    fun canDecide(now: Long) = state == "pending" && terms.createdAt <= now && terms.reviewExpiresAt > now
}

object MemberPermissionCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    fun permission(element: JsonElement, household: String): MemberPermission = malformed {
        val row = element.jsonObject
        require(row.keys == words("id kind result_form grantee scope purpose granted_at expires_at asked_from revoked_at"))
        val value = MemberPermission(
            row.string("id"), row.string("kind"), row.nullableString("result_form"), row.string("grantee"),
            row.getValue("scope").jsonArray.map { it.jsonPrimitive.let { p -> require(p.isString); p.content } }, row.string("purpose"),
            row.number("granted_at"), row.number("expires_at"), row.string("asked_from"), row.nullableNumber("revoked_at"),
        )
        require(UUID.fromString(value.id).toString() == value.id && value.kind in setOf("party", "computation"))
        require(if (value.kind == "computation") value.resultForm == "aggregate" else value.resultForm == null)
        require(value.grantee.isNotEmpty() && value.grantee != household && value.purpose.isNotBlank() && value.askedFrom.isNotEmpty())
        require(value.scope.isNotEmpty() && value.scope.distinct().size == value.scope.size && value.scope.all { it.isNotEmpty() })
        require(value.expiresAt > value.grantedAt && (value.revokedAt == null || value.revokedAt >= value.grantedAt))
        value
    }

    fun list(bytes: ByteArray, household: String): MemberPermissionList = malformed {
        val root = json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
        require(root.keys == setOf("household", "checkedAt", "permissions") && root.string("household") == household) { "scope" }
        val checkedAt = root.number("checkedAt")
        val rows = root.getValue("permissions").jsonArray.map { permission(it, household) }
        require(rows.map { it.id }.distinct().size == rows.size && rows.all { it.grantedAt <= checkedAt && (it.revokedAt == null || it.revokedAt <= checkedAt) })
        MemberPermissionList(household, checkedAt, rows)
    }

    fun request(element: JsonElement, household: String): MemberPermissionRequest = malformed {
        val root = element.jsonObject
        require(root.keys == setOf("terms", "digest", "state", "decidedAt", "permission"))
        val term = root.getValue("terms").jsonObject
        require(term.keys == setOf("profile", "requestID", "household", "action", "requester", "purpose", "fields", "createdAt", "reviewExpiresAt", "accessExpiresAt"))
        val requester = term.getValue("requester").jsonObject; require(requester.keys == setOf("id", "name"))
        val fields = term.getValue("fields").jsonArray.map { field ->
            val row = field.jsonObject; require(row.keys == setOf("id", "label")); MemberPermissionField(row.string("id"), row.string("label"))
        }
        val terms = MemberPermissionTerms(
            term.string("profile"), term.string("requestID"), term.string("household"), term.string("action"),
            MemberPermissionRequester(requester.string("id"), requester.string("name")), term.string("purpose"), fields,
            term.number("createdAt"), term.number("reviewExpiresAt"), term.number("accessExpiresAt"),
        )
        fun validText(value: String) = value.isNotEmpty() && value.length <= 512 && value.trim() == value && value.none { it.code < 32 || it.code == 127 }
        require(terms.profile == "atarasy.permission-review.1" && UUID.fromString(terms.requestId).toString() == terms.requestId)
        require(terms.household == household && listOf(terms.household, terms.action, terms.requester.id, terms.requester.name, terms.purpose).all(::validText) && terms.requester.id != household) { "scope" }
        require(terms.fields == listOf(MemberPermissionField("duplicate_check", "Whether you already have a product")))
        require(terms.createdAt < terms.reviewExpiresAt && terms.reviewExpiresAt <= terms.accessExpiresAt)
        val digest = root.string("digest"); require(Regex("^[a-f0-9]{64}$").matches(digest) && Canonical.digest(terms.canonical()) == digest) { "scope" }
        val state = root.string("state"); require(state in setOf("pending", "expired", "cancelled", "granted"))
        val decidedAt = root.nullableNumber("decidedAt")
        val permission = root.getValue("permission").takeUnless { it === JsonNull }?.let { permission(it, household) }
        if (state in setOf("pending", "expired")) require(decidedAt == null && permission == null)
        else {
            require(decidedAt != null && decidedAt >= terms.createdAt && decidedAt < terms.reviewExpiresAt)
            if (state == "cancelled") require(permission == null)
            else require(permission != null && permission.kind == "party" && permission.grantee == terms.requester.id && permission.scope == terms.fields.map { it.id } &&
                permission.purpose == terms.purpose && permission.grantedAt == decidedAt && permission.expiresAt == terms.accessExpiresAt) { "scope" }
        }
        MemberPermissionRequest(terms, digest, state, decidedAt, permission)
    }

    fun requests(bytes: ByteArray, household: String): List<MemberPermissionRequest> = malformed {
        val root = json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
        require(root.keys == setOf("household", "checkedAt", "requests") && root.string("household") == household) { "scope" }
        val checkedAt = root.number("checkedAt"); val rows = root.getValue("requests").jsonArray.map { request(it, household) }
        require(rows.map { it.id }.distinct().size == rows.size && rows.all { it.terms.createdAt <= checkedAt && (it.decidedAt == null || it.decidedAt <= checkedAt) })
        rows
    }

    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    private fun JsonObject.nullableString(key: String) = getValue(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(it.isString); it.content }
    private fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun JsonObject.nullableNumber(key: String) = getValue(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(!it.isString); it.long }.also { require(it == null || it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun words(value: String) = value.split(' ').toSet()
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: MemberFailure.ScopeMismatch) { throw e }
    catch (e: IllegalArgumentException) { if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed }
    catch (_: Exception) { throw MemberFailure.Malformed }
}

class MemberPermissions(
    private val sessions: MemberSessionClient,
    private val now: () -> Long = System::currentTimeMillis,
) {
    suspend fun list(): MemberPermissionList {
        val (reply, session) = sessions.readWithSession("/member/permissions/list"); json200(reply)
        return MemberPermissionCodec.list(reply.body, session.household)
    }
    suspend fun revoke(permission: MemberPermission): MemberPermission {
        val active = sessions.activeInfo()
        if (permission.revokedAt != null || active.expiresAt <= now()) throw MemberFailure.Unavailable
        val body = buildJsonObject { put("permission", JsonPrimitive(permission.id)) }.toString().toByteArray()
        val (reply, current) = sessions.readWithSession("/member/permissions/revoke", body = body); if (current != active) throw MemberFailure.Superseded; json200(reply)
        val root = try { Json.parseToJsonElement(reply.body.toString(Charsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        if (root.keys != setOf("household", "permission") || root["household"] != JsonPrimitive(active.household)) throw MemberFailure.ScopeMismatch
        val result = MemberPermissionCodec.permission(root.getValue("permission"), active.household)
        if (!result.sameGrant(permission) || result.revokedAt == null) throw MemberFailure.ScopeMismatch
        return result
    }
    suspend fun requests(): List<MemberPermissionRequest> {
        val (reply, session) = sessions.readWithSession("/member/permissions/requests"); json200(reply)
        return MemberPermissionCodec.requests(reply.body, session.household)
    }
    suspend fun request(id: String): MemberPermissionRequest {
        canonicalId(id); val (reply, session) = sessions.readWithSession("/member/permissions/requests/$id"); json200(reply)
        return MemberPermissionCodec.request(parse(reply.body), session.household).also { if (it.id != id) throw MemberFailure.ScopeMismatch }
    }
    suspend fun decide(review: MemberPermissionRequest, grant: Boolean): MemberPermissionRequest {
        val active = sessions.activeInfo()
        if (active.expiresAt <= now() || active.household != review.terms.household || !review.canDecide(now())) throw MemberFailure.Expired
        val body = buildJsonObject { put("digest", JsonPrimitive(review.digest)) }.toString().toByteArray()
        val action = if (grant) "grant" else "cancel"
        val (reply, current) = sessions.readWithSession("/member/permissions/requests/${review.id}/$action", body = body)
        if (current != active) throw MemberFailure.Superseded; json200(reply)
        val result = MemberPermissionCodec.request(parse(reply.body), active.household)
        if (result.digest != review.digest || result.state != if (grant) "granted" else "cancelled") throw MemberFailure.ScopeMismatch
        return result
    }
    private fun parse(bytes: ByteArray) = try { Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)) } catch (_: Exception) { throw MemberFailure.Malformed }
    private fun canonicalId(id: String) { try { if (UUID.fromString(id).toString() != id) throw MemberFailure.Malformed } catch (e: MemberFailure) { throw e } catch (_: Exception) { throw MemberFailure.Malformed } }
    private fun json200(reply: MemberHttpResponse) { if (reply.status != 200) throw MemberFailure.Http(reply.status); if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed }
}
