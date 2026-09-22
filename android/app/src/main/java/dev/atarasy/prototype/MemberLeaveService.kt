package dev.atarasy.prototype

import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/**
 * §14.3. Apple Guideline 5.1.1(v): an app that creates accounts must let a member delete one
 * in the app. `kind` is kept as the raw string the server sent: a blocker kind this build does
 * not recognise must still be shown, never silently dropped.
 */
data class MemberLeaveBlocker(val kind: String, val id: String)
data class MemberLeaveStatus(val profile: String, val household: String, val blockers: List<MemberLeaveBlocker>)
data class PreparedMemberLeave(
    val id: String, val household: String, val origin: String, val rpID: String, val digest: String,
    val credentialId: String, val expiresAt: Long, val publicKeyJson: String,
)
data class MemberLeft(val profile: String, val household: String, val leftAt: Long, val deleted: JsonElement)

/**
 * `node` and `privateRecords` are kept as the exact JSON text the host sent for those two
 * fields, so a saved export file reproduces them byte-for-byte rather than through a
 * decode/re-encode round trip that could reorder keys or reformat numbers.
 */
data class MemberExport(val profile: String, val household: String, val exportedAt: Long, val node: String, val privateRecords: String)

/** Assembles the full export document for saving to a file. The two byte-exact fields are
 * spliced in verbatim; the three scalar fields round-trip losslessly. */
fun MemberExport.fileContents(): ByteArray = buildString {
    append('{')
    append("\"profile\":").append(JsonPrimitive(profile))
    append(",\"household\":").append(JsonPrimitive(household))
    append(",\"exportedAt\":").append(exportedAt)
    append(",\"node\":").append(node)
    append(",\"privateRecords\":").append(privateRecords)
    append('}')
}.toByteArray(Charsets.UTF_8)

/** Thrown on a `409 leave_blocked`. Carries the same blocker list the status route reports, so
 * a caller does not need a second read to show why the request was refused. A 409 from submit
 * means the review was already spent and nothing was deleted. */
class MemberLeaveBlockedException(val blockers: List<MemberLeaveBlocker>) : Exception("Account deletion is blocked")

object MemberLeaveWire {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val statusKeys = setOf("profile", "household", "blockers")
    private val blockerKeys = setOf("kind", "id")
    private val blockedKeys = setOf("error", "blockers")
    private val prepareKeys = setOf("profile", "id", "household", "origin", "rpID", "expiresAt", "digest", "publicKey")
    private val leftKeys = setOf("profile", "household", "leftAt", "deleted")
    private val exportKeys = setOf("profile", "household", "exportedAt", "node", "privateRecords")

    fun digest(value: String) = Regex("^[A-Za-z0-9_-]{43}$").matches(value)
    fun uuid(value: String) = try { UUID.fromString(value).toString() == value } catch (_: Exception) { false }

    fun blockers(element: JsonElement): List<MemberLeaveBlocker> = element.jsonArray.map { row ->
        val obj = row.jsonObject; require(obj.keys == blockerKeys)
        MemberLeaveBlocker(obj.text("kind"), obj.text("id")).also { require(it.kind.isNotEmpty() && it.id.isNotEmpty()) }
    }

    fun status(bytes: ByteArray, household: String): MemberLeaveStatus = malformed {
        val row = objectOf(bytes); require(row.keys == statusKeys)
        val value = MemberLeaveStatus(row.text("profile"), row.text("household"), blockers(row.getValue("blockers")))
        require(value.profile == "atarasy.member-leave-status.1" && value.household == household) { "scope" }
        value
    }

    fun blocked(bytes: ByteArray): List<MemberLeaveBlocker> = malformed {
        val row = objectOf(bytes); require(row.keys == blockedKeys)
        require(row.text("error") == "leave_blocked") { "scope" }
        blockers(row.getValue("blockers"))
    }

    fun prepare(text: String, environment: MemberEnvironment, household: String, now: Long): PreparedMemberLeave = malformed {
        val root = json.parseToJsonElement(text).jsonObject; require(root.keys == prepareKeys)
        require(root.text("profile") == "atarasy.member-leave.1" && root.text("household") == household) { "scope" }
        val id = root.text("id"); require(uuid(id))
        val origin = root.text("origin"); require(origin == environment.origin) { "scope" }
        val rpID = root.text("rpID"); require(rpID == environment.relyingPartyId) { "scope" }
        val leaveDigest = root.text("digest"); require(digest(leaveDigest))
        val expiresAt = root.number("expiresAt"); require(expiresAt > now)
        val publicKey = root.getValue("publicKey").jsonObject
        require(publicKey.keys == setOf("challenge", "rpId", "timeout", "userVerification", "allowCredentials"))
        require(publicKey.text("rpId") == rpID && publicKey.text("userVerification") == "required" && publicKey.text("challenge") == leaveDigest) { "scope" }
        publicKey.number("timeout")
        val allowed = publicKey.getValue("allowCredentials").jsonArray; require(allowed.size == 1) { "scope" }
        val credential = allowed.single().jsonObject
        require(credential.keys == setOf("type", "id") && credential.text("type") == "public-key")
        val publicKeyJson = MemberAuthenticationWire.rawObjectMember(text, "publicKey") ?: error("publicKey")
        PreparedMemberLeave(id, household, origin, rpID, leaveDigest, credential.text("id"), expiresAt, publicKeyJson)
    }

    fun assertion(value: String, prepared: PreparedMemberLeave, acceptedOrigins: Set<String>): JsonObject = malformed {
        val assertionObject = json.parseToJsonElement(value).jsonObject
        require(assertionObject.text("id") == prepared.credentialId) { "scope" }
        val response = assertionObject.getValue("response").jsonObject
        val encoded = response.text("clientDataJSON")
        val client = json.parseToJsonElement(Base64.getUrlDecoder().decode(encoded).toString(Charsets.UTF_8)).jsonObject
        require(
            client.text("type") == "webauthn.get" && client.text("challenge") == prepared.digest && client.text("origin") in acceptedOrigins &&
                !client.containsKey("topOrigin") && (!client.containsKey("crossOrigin") || client["crossOrigin"] == JsonPrimitive(false)),
        ) { "scope" }
        assertionObject
    }

    fun left(bytes: ByteArray, prepared: PreparedMemberLeave, household: String): MemberLeft = malformed {
        val row = objectOf(bytes); require(row.keys == leftKeys)
        val value = MemberLeft(row.text("profile"), row.text("household"), row.number("leftAt"), row.getValue("deleted"))
        require(value.profile == "atarasy.member-left.1" && value.household == prepared.household && value.household == household) { "scope" }
        value
    }

    fun export(text: String, household: String): MemberExport = malformed {
        val root = json.parseToJsonElement(text).jsonObject; require(root.keys == exportKeys)
        require(root.text("profile") == "atarasy.member-export.1" && root.text("household") == household) { "scope" }
        val exportedAt = root.number("exportedAt")
        val node = MemberAuthenticationWire.rawObjectMember(text, "node") ?: error("node")
        val privateRecords = MemberAuthenticationWire.rawObjectMember(text, "privateRecords") ?: error("privateRecords")
        // Defence in depth: the raw slice above must be valid JSON on its own, or the export
        // would silently carry a corrupt fragment as "byte exact".
        json.parseToJsonElement(node); json.parseToJsonElement(privateRecords)
        MemberExport("atarasy.member-export.1", household, exportedAt, node, privateRecords)
    }

    fun objectOf(bytes: ByteArray) = try { json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
    fun JsonObject.text(key: String) = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
    inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: MemberFailure.ScopeMismatch) { throw e }
    catch (e: IllegalArgumentException) { if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed }
    catch (_: Exception) { throw MemberFailure.Malformed }
}

class MemberLeaveService(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
    private val now: () -> Long = System::currentTimeMillis,
    private val acceptedOrigins: Set<String> = setOf(environment.origin),
) {
    suspend fun status(): MemberLeaveStatus {
        val (reply, session) = sessions.readWithSession("/member/account/leave"); json200(reply)
        return MemberLeaveWire.status(reply.body, session.household)
    }

    suspend fun prepare(): PreparedMemberLeave {
        val (reply, session) = sessions.readWithSession("/member/account/leave/prepare", body = "{}".toByteArray())
        if (reply.status == 409) throw MemberLeaveBlockedException(blocked(reply))
        json200(reply)
        return MemberLeaveWire.prepare(reply.body.toString(Charsets.UTF_8), environment, session.household, now())
    }

    /** Prepares a fresh review, signs it with the passkey, and submits it. A blocker found
     * after the signature was verified means the server spent the review and deleted nothing:
     * this is a refusal to show, not an unconfirmed result. On success the local session is
     * removed the same way `MemberHostMoveService.retire` removes it once a host move has
     * genuinely ended access on this host. */
    suspend fun submit(prepared: PreparedMemberLeave, assertionJson: String): MemberLeft {
        val assertion = MemberLeaveWire.assertion(assertionJson, prepared, acceptedOrigins)
        val body = buildJsonObject { put("preparation", JsonPrimitive(prepared.id)); put("assertion", assertion) }.toString().toByteArray()
        val (reply, session) = sessions.readWithSession("/member/account/leave/submit", body = body)
        if (reply.status == 409) throw MemberLeaveBlockedException(blocked(reply))
        json200(reply)
        val value = MemberLeaveWire.left(reply.body, prepared, session.household)
        sessions.removeRetiredLocalSession(session)
        return value
    }

    /** A member's full export, offered before deletion so leaving costs nothing they cannot
     * keep. Read-only; never itself a step of deletion. */
    suspend fun export(): MemberExport {
        val (reply, session) = sessions.readWithSession("/member/account/export"); json200(reply)
        return MemberLeaveWire.export(reply.body.toString(Charsets.UTF_8), session.household)
    }

    private fun json200(reply: MemberHttpResponse) {
        if (reply.status != 200) throw MemberFailure.Http(reply.status)
        if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed
    }
    private fun blocked(reply: MemberHttpResponse): List<MemberLeaveBlocker> {
        if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed
        return MemberLeaveWire.blocked(reply.body)
    }
}
