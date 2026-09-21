package dev.atarasy.prototype

import dev.atarasy.prototype.MemberHostMoveWire.number
import dev.atarasy.prototype.MemberHostMoveWire.text
import java.security.MessageDigest
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

data class MemberHostExport(
    val id: String, val household: String, val sourceOrigin: String, val targetOrigin: String,
    val digest: String, val archive: String, val privateRecords: List<MemberPrivateNodeRecord>,
)
data class MemberHostImportReceipt(
    val profile: String, val move: String, val household: String, val sourceOrigin: String, val targetOrigin: String,
    val archiveDigest: String, val nodeDigest: String, val privateRecords: Long, val importedAt: Long,
)
data class MemberHostImportAttestation(val receipt: MemberHostImportReceipt, val wire: JsonObject)
data class PreparedMemberHostImportAttestation(val receipt: MemberHostImportReceipt, val ceremony: MemberRecoveryCeremony, val digest: String)
data class PreparedMemberHostRetirement(val ceremony: MemberRecoveryCeremony, val targetOrigin: String, val move: String, val attestation: JsonObject)
data class MemberHostRetirement(
    val profile: String, val move: String, val household: String, val targetOrigin: String,
    val archiveDigest: String, val receiptDigest: String, val retiredAt: Long,
)

object MemberHostMoveWire {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val receiptKeys = setOf("profile", "move", "household", "sourceOrigin", "targetOrigin", "archiveDigest", "nodeDigest", "privateRecords", "importedAt")
    fun digest(value: String) = Regex("^[A-Za-z0-9_-]{43}$").matches(value)
    fun uuid(value: String) = try { UUID.fromString(value).toString() == value } catch (_: Exception) { false }
    fun archiveBytes(value: String): ByteArray {
        if (value.isEmpty() || value.length > 8_000_000) throw MemberFailure.Malformed
        return MemberPrivateNodeCodec.data(value).also { if (it.size > 6_000_000) throw MemberFailure.Malformed }
    }
    fun origin(value: String): String = try { MemberEnvironment.create("move", value).origin.also { require(it == value) } } catch (_: Exception) { throw MemberFailure.Malformed }
    fun receipt(element: JsonElement, household: String, source: String? = null, target: String? = null): MemberHostImportReceipt = malformed {
        val row = element.jsonObject; require(row.keys == receiptKeys)
        val value = MemberHostImportReceipt(
            row.text("profile"), row.text("move"), row.text("household"), row.text("sourceOrigin"), row.text("targetOrigin"),
            row.text("archiveDigest"), row.text("nodeDigest"), row.number("privateRecords"), row.number("importedAt"),
        )
        require(value.profile == "atarasy.member-host-import-receipt.1" && uuid(value.move) && value.household == household) { "scope" }
        require(digest(value.archiveDigest) && Regex("^[a-f0-9]{64}$").matches(value.nodeDigest) && value.privateRecords <= 10_000)
        require(origin(value.sourceOrigin) == value.sourceOrigin && origin(value.targetOrigin) == value.targetOrigin)
        require(source == null || source == value.sourceOrigin) { "scope" }; require(target == null || target == value.targetOrigin) { "scope" }; value
    }
    fun recordJson(value: MemberPrivateNodeRecord) = buildJsonObject {
        put("id", JsonPrimitive(value.id)); put("revision", JsonPrimitive(value.revision)); put("updatedAt", JsonPrimitive(value.updatedAt)); put("envelope", MemberPrivateNodeCodec.envelopeJson(value.envelope))
    }
    fun assertion(value: String, ceremony: MemberRecoveryCeremony, environment: MemberEnvironment, origins: Set<String>): JsonObject {
        val row = objectOf(value); if (row.keys.none { it == "rawId" } || row["rawId"] != row["id"]) throw MemberFailure.ScopeMismatch
        return MemberRecoveryWire.assertion(value, ceremony, environment, origins)
    }
    fun objectOf(bytes: ByteArray) = try { json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
    fun objectOf(value: String) = try { json.parseToJsonElement(value).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
    fun JsonObject.text(key: String) = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    fun JsonObject.number(key: String) = getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
    inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: MemberFailure.ScopeMismatch) { throw e }
    catch (e: IllegalArgumentException) { if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed }
    catch (_: Exception) { throw MemberFailure.Malformed }
}

class MemberHostMoveService(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
    private val now: () -> Long = System::currentTimeMillis,
    private val acceptedOrigins: Set<String> = setOf(environment.origin),
) {
    suspend fun export(target: MemberEnvironment): MemberHostExport {
        if (target.origin == environment.origin) throw MemberFailure.Malformed
        val body = buildJsonObject { put("targetOrigin", JsonPrimitive(target.origin)) }.toString().toByteArray()
        val (reply, session) = sessions.readWithSession("/member/host-move/export", body = body); json(reply, 201)
        val root = MemberHostMoveWire.objectOf(reply.body)
        if (root.keys != setOf("profile", "id", "household", "sourceOrigin", "targetOrigin", "digest", "archive", "createdAt")) throw MemberFailure.Malformed
        val id = root.text("id"); val encoded = root.text("archive"); val digest = root.text("digest"); root.number("createdAt")
        if (root.text("profile") != "atarasy.member-host-export.1" || !MemberHostMoveWire.uuid(id) || root.text("household") != session.household ||
            root.text("sourceOrigin") != environment.origin || root.text("targetOrigin") != target.origin) throw MemberFailure.ScopeMismatch
        val bytes = MemberHostMoveWire.archiveBytes(encoded)
        if (!MemberHostMoveWire.digest(digest) || MemberPrivateNodeCodec.b64(MessageDigest.getInstance("SHA-256").digest(bytes)) != digest) throw MemberFailure.Malformed
        val archive = MemberHostMoveWire.objectOf(bytes)
        if (archive.keys != setOf("profile", "move", "household", "sourceOrigin", "targetOrigin", "exportedAt", "node", "privateRecords", "recovery") ||
            archive.text("profile") != "atarasy.member-host-archive.1" || archive.text("move") != id || archive.text("household") != session.household ||
            archive.text("sourceOrigin") != environment.origin || archive.text("targetOrigin") != target.origin || archive["node"] !is JsonObject || archive["recovery"] !is JsonObject) throw MemberFailure.ScopeMismatch
        archive.number("exportedAt"); val records = archive.getValue("privateRecords").jsonArray.map(MemberPrivateNodeCodec::record)
        if (records.size > 10_000 || records.map { it.id }.distinct().size != records.size) throw MemberFailure.Malformed
        return MemberHostExport(id, session.household, environment.origin, target.origin, digest, encoded, records)
    }

    suspend fun import(value: MemberHostExport, records: List<MemberPrivateNodeRecord>): MemberHostImportReceipt {
        if (records.size > 10_000 || records.map { it.id }.distinct().size != records.size) throw MemberFailure.Malformed
        val body = buildJsonObject {
            put("archive", JsonPrimitive(value.archive)); put("digest", JsonPrimitive(value.digest)); put("privateRecords", buildJsonArray { records.forEach { add(MemberHostMoveWire.recordJson(it)) } })
        }.toString().toByteArray()
        val (reply, session) = sessions.readWithSession("/member/host-move/import", body = body); json(reply, 201)
        return MemberHostMoveWire.receipt(MemberHostMoveWire.objectOf(reply.body), session.household, value.sourceOrigin, environment.origin).also {
            if (it.move != value.id || it.archiveDigest != value.digest || it.privateRecords != records.size.toLong()) throw MemberFailure.ScopeMismatch
        }
    }

    suspend fun importStatus(digest: String): MemberHostImportReceipt {
        if (!MemberHostMoveWire.digest(digest)) throw MemberFailure.Malformed
        val (reply, session) = sessions.readWithSession("/member/host-move/imports/$digest"); json(reply, 200)
        return MemberHostMoveWire.receipt(MemberHostMoveWire.objectOf(reply.body), session.household, target = environment.origin).also { if (it.archiveDigest != digest) throw MemberFailure.ScopeMismatch }
    }

    suspend fun prepareImportAttestation(digest: String): PreparedMemberHostImportAttestation {
        if (!MemberHostMoveWire.digest(digest)) throw MemberFailure.Malformed
        val (reply, session) = sessions.readWithSession("/member/host-move/imports/$digest/prepare", body = "{}".toByteArray()); json(reply, 200)
        val text = reply.body.toString(Charsets.UTF_8); val root = MemberHostMoveWire.objectOf(reply.body)
        if (root.keys != setOf("profile", "receipt", "id", "expiresAt", "publicKey") || root.text("profile") != "atarasy.member-host-import-attestation-review.1") throw MemberFailure.Malformed
        val receipt = MemberHostMoveWire.receipt(root.getValue("receipt"), session.household, target = environment.origin)
        if (receipt.archiveDigest != digest) throw MemberFailure.ScopeMismatch
        return PreparedMemberHostImportAttestation(receipt, MemberRecoveryWire.ceremony(text, environment, now()), digest)
    }

    suspend fun attest(prepared: PreparedMemberHostImportAttestation, responseJson: String): MemberHostImportAttestation {
        val assertion = MemberHostMoveWire.assertion(responseJson, prepared.ceremony, environment, acceptedOrigins)
        val body = buildJsonObject { put("preparation", JsonPrimitive(prepared.ceremony.id)); put("assertion", assertion) }.toString().toByteArray()
        val (reply, session) = sessions.readWithSession("/member/host-move/imports/${prepared.digest}/attest", body = body); json(reply, 200)
        val root = MemberHostMoveWire.objectOf(reply.body)
        if (root.keys != setOf("profile", "receipt", "proof") || root.text("profile") != "atarasy.member-host-import-attestation.1") throw MemberFailure.Malformed
        val proof = root.getValue("proof").jsonObject
        if (proof.keys != setOf("credential", "assertion") || proof.text("credential") != assertion.getValue("id").jsonPrimitive.content || proof.getValue("assertion") != assertion) throw MemberFailure.ScopeMismatch
        val receipt = MemberHostMoveWire.receipt(root.getValue("receipt"), session.household, target = environment.origin)
        if (receipt != prepared.receipt) throw MemberFailure.ScopeMismatch
        return MemberHostImportAttestation(receipt, root)
    }

    suspend fun prepareRetirement(move: String, attestation: MemberHostImportAttestation): PreparedMemberHostRetirement {
        if (!MemberHostMoveWire.uuid(move)) throw MemberFailure.Malformed
        val body = buildJsonObject { put("attestation", attestation.wire) }.toString().toByteArray()
        val (reply, session) = sessions.readWithSession("/member/host-move/$move/retirement/prepare", body = body); json(reply, 200)
        val text = reply.body.toString(Charsets.UTF_8); val root = MemberHostMoveWire.objectOf(reply.body)
        if (root.keys != setOf("profile", "move", "attestation", "receiptDigest", "id", "expiresAt", "publicKey") || root.text("profile") != "atarasy.member-host-retirement-review.1" || root.getValue("attestation") != attestation.wire || !MemberHostMoveWire.digest(root.text("receiptDigest"))) throw MemberFailure.ScopeMismatch
        val fixed = root.getValue("move").jsonObject
        if (fixed.keys != setOf("id", "household", "sourceOrigin", "targetOrigin", "digest", "state", "createdAt", "retiredAt", "receiptDigest") || fixed.text("id") != move || fixed.text("household") != session.household || fixed.text("sourceOrigin") != environment.origin || fixed.text("state") != "prepared") throw MemberFailure.ScopeMismatch
        val target = MemberHostMoveWire.origin(fixed.text("targetOrigin")); fixed.number("createdAt")
        return PreparedMemberHostRetirement(MemberRecoveryWire.ceremony(text, environment, now()), target, move, attestation.wire)
    }

    suspend fun retire(prepared: PreparedMemberHostRetirement, responseJson: String): MemberHostRetirement {
        val before = sessions.activeInfo(); val assertion = MemberHostMoveWire.assertion(responseJson, prepared.ceremony, environment, acceptedOrigins)
        val body = buildJsonObject { put("preparation", JsonPrimitive(prepared.ceremony.id)); put("attestation", prepared.attestation); put("assertion", assertion) }.toString().toByteArray()
        val (reply, session) = sessions.readWithSession("/member/host-move/${prepared.move}/retirement/retire", body = body); json(reply, 200)
        if (session != before) throw MemberFailure.Superseded
        val root = MemberHostMoveWire.objectOf(reply.body)
        if (root.keys != setOf("profile", "move", "household", "targetOrigin", "archiveDigest", "receiptDigest", "retiredAt")) throw MemberFailure.Malformed
        val value = MemberHostRetirement(root.text("profile"), root.text("move"), root.text("household"), root.text("targetOrigin"), root.text("archiveDigest"), root.text("receiptDigest"), root.number("retiredAt"))
        if (value.profile != "atarasy.member-host-retirement.1" || value.move != prepared.move || value.household != session.household || value.targetOrigin != prepared.targetOrigin || !MemberHostMoveWire.digest(value.archiveDigest) || !MemberHostMoveWire.digest(value.receiptDigest)) throw MemberFailure.ScopeMismatch
        sessions.removeRetiredLocalSession(session); return value
    }

    private fun json(reply: MemberHttpResponse, status: Int) {
        if (reply.status != status) throw MemberFailure.Http(reply.status)
        if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed
    }
}
