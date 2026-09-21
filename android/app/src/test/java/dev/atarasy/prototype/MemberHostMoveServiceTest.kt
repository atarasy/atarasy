package dev.atarasy.prototype

import java.security.MessageDigest
import java.util.Base64
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MemberHostMoveServiceTest {
    private val source = MemberEnvironment.create("source", "https://source.example")
    private val target = MemberEnvironment.create("target", "https://target.example")
    private val household = "key:" + "A".repeat(43)
    private val info = MemberSessionInfo("session", household, emptyList(), 1_800_000_100_000)
    private val token = "amr1_" + "A".repeat(43)
    private val move = "11111111-1111-4111-8111-111111111111"
    private val credential = "YQ"
    private val record = MemberPrivateNodeRecord(
        "33333333-3333-4333-8333-333333333333", 1, 1_800_000_000_000,
        MemberPrivateNodeEnvelope(nonce = MemberPrivateNodeCodec.b64(ByteArray(12) { 1 }), ciphertext = MemberPrivateNodeCodec.b64(ByteArray(32) { 2 })),
    )

    private fun sessionJson() = buildJsonObject {
        put("id", JsonPrimitive(info.id)); put("household", JsonPrimitive(info.household)); put("presenters", buildJsonArray {}); put("expiresAt", JsonPrimitive(info.expiresAt))
    }
    private fun response(environment: MemberEnvironment, path: String, value: JsonObject, status: Int = 200) =
        MemberHttpResponse(environment.origin + path, environment.origin + path, status, "application/json", "no-store", value.toString().toByteArray())
    private fun client(environment: MemberEnvironment, replies: List<MemberHttpResponse>): Pair<MemberHostMoveService, DecisionTransport> {
        val transport = DecisionTransport(ArrayDeque(listOf(response(environment, "/auth/session", sessionJson())) + replies))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession(token, info))) { 1_800_000_000_000 }
        runBlocking { sessions.restore(household) }
        return MemberHostMoveService(environment, sessions, now = { 1_800_000_000_000 }) to transport
    }
    private fun ceremony(profile: String, receipt: JsonObject? = null, attestation: JsonObject? = null): JsonObject = buildJsonObject {
        put("profile", JsonPrimitive(profile))
        if (receipt != null) put("receipt", receipt)
        if (attestation != null) {
            put("move", buildJsonObject {
                put("id", JsonPrimitive(move)); put("household", JsonPrimitive(household)); put("sourceOrigin", JsonPrimitive(source.origin)); put("targetOrigin", JsonPrimitive(target.origin))
                put("digest", JsonPrimitive(attestation.getValue("receipt").jsonObject.getValue("archiveDigest").jsonPrimitive.content)); put("state", JsonPrimitive("prepared")); put("createdAt", JsonPrimitive(1_800_000_000_000)); put("retiredAt", kotlinx.serialization.json.JsonNull); put("receiptDigest", kotlinx.serialization.json.JsonNull)
            })
            put("attestation", attestation); put("receiptDigest", JsonPrimitive("D".repeat(43)))
        }
        put("id", JsonPrimitive("22222222-2222-4222-8222-222222222222")); put("expiresAt", JsonPrimitive(1_800_000_001_000))
        put("publicKey", buildJsonObject {
            put("challenge", JsonPrimitive(MemberPrivateNodeCodec.b64(ByteArray(32) { 3 }))); put("rpId", JsonPrimitive(if (receipt == null && attestation != null) source.relyingPartyId else target.relyingPartyId))
            put("timeout", JsonPrimitive(1_000)); put("userVerification", JsonPrimitive("required")); put("allowCredentials", buildJsonArray { add(buildJsonObject { put("type", JsonPrimitive("public-key")); put("id", JsonPrimitive(credential)) }) })
        })
    }
    private fun assertion(environment: MemberEnvironment): String {
        val client = buildJsonObject { put("type", JsonPrimitive("webauthn.get")); put("challenge", JsonPrimitive(MemberPrivateNodeCodec.b64(ByteArray(32) { 3 }))); put("origin", JsonPrimitive(environment.origin)) }
        return buildJsonObject {
            put("id", JsonPrimitive(credential)); put("rawId", JsonPrimitive(credential)); put("type", JsonPrimitive("public-key")); put("response", buildJsonObject {
                put("clientDataJSON", JsonPrimitive(Base64.getUrlEncoder().withoutPadding().encodeToString(client.toString().toByteArray()))); put("authenticatorData", JsonPrimitive("YQ")); put("signature", JsonPrimitive("YQ")); put("userHandle", kotlinx.serialization.json.JsonNull)
            })
        }.toString()
    }

    @Test fun `archive import attestation and retirement keep exact host boundaries`() = runBlocking {
        val archiveObject = buildJsonObject {
            put("profile", JsonPrimitive("atarasy.member-host-archive.1")); put("move", JsonPrimitive(move)); put("household", JsonPrimitive(household)); put("sourceOrigin", JsonPrimitive(source.origin)); put("targetOrigin", JsonPrimitive(target.origin)); put("exportedAt", JsonPrimitive(1_800_000_000_000))
            put("node", buildJsonObject {}); put("privateRecords", buildJsonArray { add(MemberHostMoveWire.recordJson(record)) }); put("recovery", buildJsonObject {})
        }
        val archiveBytes = archiveObject.toString().toByteArray(); val encoded = MemberPrivateNodeCodec.b64(archiveBytes); val digest = MemberPrivateNodeCodec.b64(MessageDigest.getInstance("SHA-256").digest(archiveBytes))
        val exportReply = buildJsonObject {
            put("profile", JsonPrimitive("atarasy.member-host-export.1")); put("id", JsonPrimitive(move)); put("household", JsonPrimitive(household)); put("sourceOrigin", JsonPrimitive(source.origin)); put("targetOrigin", JsonPrimitive(target.origin)); put("digest", JsonPrimitive(digest)); put("archive", JsonPrimitive(encoded)); put("createdAt", JsonPrimitive(1_800_000_000_000))
        }
        val receipt = buildJsonObject {
            put("profile", JsonPrimitive("atarasy.member-host-import-receipt.1")); put("move", JsonPrimitive(move)); put("household", JsonPrimitive(household)); put("sourceOrigin", JsonPrimitive(source.origin)); put("targetOrigin", JsonPrimitive(target.origin)); put("archiveDigest", JsonPrimitive(digest)); put("nodeDigest", JsonPrimitive("a".repeat(64))); put("privateRecords", JsonPrimitive(1)); put("importedAt", JsonPrimitive(1_800_000_000_001))
        }
        val targetAssertion = MemberHostMoveWire.objectOf(assertion(target)); val attestation = buildJsonObject {
            put("profile", JsonPrimitive("atarasy.member-host-import-attestation.1")); put("receipt", receipt); put("proof", buildJsonObject { put("credential", JsonPrimitive(credential)); put("assertion", targetAssertion) })
        }
        val retirement = buildJsonObject {
            put("profile", JsonPrimitive("atarasy.member-host-retirement.1")); put("move", JsonPrimitive(move)); put("household", JsonPrimitive(household)); put("targetOrigin", JsonPrimitive(target.origin)); put("archiveDigest", JsonPrimitive(digest)); put("receiptDigest", JsonPrimitive("D".repeat(43))); put("retiredAt", JsonPrimitive(1_800_000_000_002))
        }
        val (sourceService, sourceTransport) = client(source, listOf(
            response(source, "/member/host-move/export", exportReply, 201), response(source, "/member/host-move/$move/retirement/prepare", ceremony("atarasy.member-host-retirement-review.1", attestation = attestation)), response(source, "/member/host-move/$move/retirement/retire", retirement),
        ))
        val (targetService, targetTransport) = client(target, listOf(
            response(target, "/member/host-move/import", receipt, 201), response(target, "/member/host-move/imports/$digest/prepare", ceremony("atarasy.member-host-import-attestation-review.1", receipt = receipt)), response(target, "/member/host-move/imports/$digest/attest", attestation),
        ))
        val exported = sourceService.export(target); assertEquals(listOf(record), exported.privateRecords)
        assertEquals(digest, targetService.import(exported, listOf(record)).archiveDigest)
        val review = targetService.prepareImportAttestation(digest); val proof = targetService.attest(review, assertion(target)); assertEquals(review.receipt, proof.receipt)
        val prepared = sourceService.prepareRetirement(move, proof); assertEquals(target.origin, prepared.targetOrigin)
        assertEquals(target.origin, sourceService.retire(prepared, assertion(source)).targetOrigin)
        assertEquals(listOf("/auth/session", "/member/host-move/export", "/member/host-move/$move/retirement/prepare", "/member/host-move/$move/retirement/retire"), sourceTransport.requests.map { it.path })
        assertEquals(listOf("/auth/session", "/member/host-move/import", "/member/host-move/imports/$digest/prepare", "/member/host-move/imports/$digest/attest"), targetTransport.requests.map { it.path })
        assertThrows(MemberFailure.Expired::class.java) { runBlocking { sourceService.importStatus(digest) } }
        Unit
    }

    @Test fun `corrupt archive digest stops before any target operation`() = runBlocking {
        val malformed = buildJsonObject {
            put("profile", JsonPrimitive("atarasy.member-host-export.1")); put("id", JsonPrimitive(move)); put("household", JsonPrimitive(household)); put("sourceOrigin", JsonPrimitive(source.origin)); put("targetOrigin", JsonPrimitive(target.origin)); put("digest", JsonPrimitive("A".repeat(43))); put("archive", JsonPrimitive(MemberPrivateNodeCodec.b64("{}".toByteArray()))); put("createdAt", JsonPrimitive(1_800_000_000_000))
        }
        val (service, transport) = client(source, listOf(response(source, "/member/host-move/export", malformed, 201)))
        assertThrows(MemberFailure.Malformed::class.java) { runBlocking { service.export(target) } }
        assertEquals(2, transport.requests.size)
    }
}
