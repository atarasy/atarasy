package dev.atarasy.prototype

import java.util.Base64
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MemberLeaveServiceTest {
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val household = "key:" + "A".repeat(43)
    private val info = MemberSessionInfo("session", household, emptyList(), 1_800_000_100_000)
    private val token = "amr1_" + "A".repeat(43)
    private val credential = "YQ"
    private val digest = MemberPrivateNodeCodec.b64(ByteArray(32) { 3 })

    private fun sessionJson() = buildJsonObject {
        put("id", JsonPrimitive(info.id)); put("household", JsonPrimitive(info.household)); put("presenters", buildJsonArray {}); put("expiresAt", JsonPrimitive(info.expiresAt))
    }
    private fun response(path: String, value: JsonObject, status: Int = 200) =
        MemberHttpResponse(environment.origin + path, environment.origin + path, status, "application/json", "no-store", value.toString().toByteArray())
    private fun client(replies: List<MemberHttpResponse>): Pair<MemberLeaveService, DecisionTransport> {
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", sessionJson())) + replies))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession(token, info))) { 1_800_000_000_000 }
        runBlocking { sessions.restore(household) }
        return MemberLeaveService(environment, sessions, now = { 1_800_000_000_000 }) to transport
    }
    private fun blockers() = buildJsonArray {
        add(buildJsonObject { put("kind", JsonPrimitive("offer_in_progress")); put("id", JsonPrimitive("11111111-1111-4111-8111-111111111111")) })
        add(buildJsonObject { put("kind", JsonPrimitive("a_future_kind_this_build_does_not_know")); put("id", JsonPrimitive("22222222-2222-4222-8222-222222222222")) })
    }
    private fun prepareReply(digestValue: String = digest) = buildJsonObject {
        put("profile", JsonPrimitive("atarasy.member-leave.1")); put("id", JsonPrimitive("33333333-3333-4333-8333-333333333333")); put("household", JsonPrimitive(household))
        put("origin", JsonPrimitive(environment.origin)); put("rpID", JsonPrimitive(environment.relyingPartyId)); put("expiresAt", JsonPrimitive(1_800_000_001_000)); put("digest", JsonPrimitive(digestValue))
        put("publicKey", buildJsonObject {
            put("challenge", JsonPrimitive(digestValue)); put("rpId", JsonPrimitive(environment.relyingPartyId)); put("timeout", JsonPrimitive(1_000)); put("userVerification", JsonPrimitive("required"))
            put("allowCredentials", buildJsonArray { add(buildJsonObject { put("type", JsonPrimitive("public-key")); put("id", JsonPrimitive(credential)) }) })
        })
    }
    private fun blockedReply() = buildJsonObject { put("error", JsonPrimitive("leave_blocked")); put("blockers", blockers()) }
    private fun assertionFor(prepared: PreparedMemberLeave): String {
        val clientData = buildJsonObject { put("type", JsonPrimitive("webauthn.get")); put("challenge", JsonPrimitive(prepared.digest)); put("origin", JsonPrimitive(environment.origin)) }
        return buildJsonObject {
            put("id", JsonPrimitive(prepared.credentialId)); put("rawId", JsonPrimitive(prepared.credentialId)); put("type", JsonPrimitive("public-key"))
            put("response", buildJsonObject {
                put("clientDataJSON", JsonPrimitive(Base64.getUrlEncoder().withoutPadding().encodeToString(clientData.toString().toByteArray())))
                put("authenticatorData", JsonPrimitive("YQ")); put("signature", JsonPrimitive("YQ")); put("userHandle", kotlinx.serialization.json.JsonNull)
            })
        }.toString()
    }
    private fun leftReply() = buildJsonObject {
        put("profile", JsonPrimitive("atarasy.member-left.1")); put("household", JsonPrimitive(household)); put("leftAt", JsonPrimitive(1_800_000_000_500))
        put("deleted", buildJsonObject { put("offers", JsonPrimitive(3)); put("permissions", JsonPrimitive(1)) })
    }

    @Test fun `status keeps an unknown blocker kind instead of dropping it`() = runBlocking {
        val (service, transport) = client(listOf(response("/member/account/leave", buildJsonObject { put("profile", JsonPrimitive("atarasy.member-leave-status.1")); put("household", JsonPrimitive(household)); put("blockers", blockers()) })))
        val status = service.status()
        assertEquals(household, status.household)
        assertEquals(listOf("offer_in_progress", "a_future_kind_this_build_does_not_know"), status.blockers.map { it.kind })
        assertEquals(listOf("/auth/session", "/member/account/leave"), transport.requests.map { it.path })
    }

    @Test fun `status with no blockers decodes to an empty list`() = runBlocking {
        val (service, _) = client(listOf(response("/member/account/leave", buildJsonObject { put("profile", JsonPrimitive("atarasy.member-leave-status.1")); put("household", JsonPrimitive(household)); put("blockers", buildJsonArray {}) })))
        assertTrue(service.status().blockers.isEmpty())
    }

    @Test fun `prepare decodes a ceremony bound to this household and origin`() = runBlocking {
        val (service, _) = client(listOf(response("/member/account/leave/prepare", prepareReply(), 200)))
        val prepared = service.prepare()
        assertEquals(household, prepared.household); assertEquals(environment.origin, prepared.origin); assertEquals(environment.relyingPartyId, prepared.rpID)
        assertEquals(digest, prepared.digest); assertEquals(credential, prepared.credentialId)
    }

    @Test fun `prepare surfaces a 409 as a blocked exception rather than a generic http failure`() = runBlocking {
        val (service, _) = client(listOf(response("/member/account/leave/prepare", blockedReply(), 409)))
        val failure = assertThrows(MemberLeaveBlockedException::class.java) { runBlocking { service.prepare() } }
        assertEquals(listOf("offer_in_progress", "a_future_kind_this_build_does_not_know"), failure.blockers.map { it.kind })
    }

    @Test fun `submit removes the local session on success`() = runBlocking {
        val (service, sessions) = clientWithSessions(listOf(response("/member/account/leave/prepare", prepareReply()), response("/member/account/leave/submit", leftReply())))
        val prepared = service.prepare()
        val result = service.submit(prepared, assertionFor(prepared))
        assertEquals("atarasy.member-left.1", result.profile); assertEquals(household, result.household); assertEquals(1_800_000_000_500L, result.leftAt)
        // The account is deleted: this device must no longer read as signed in, the same way a
        // host move's source access ends once `MemberHostMoveService.retire` succeeds.
        assertThrows(MemberFailure.Expired::class.java) { runBlocking { sessions.activeInfo() } }
        Unit
    }

    @Test fun `submit sends the preparation id alongside the assertion`() = runBlocking {
        val (service, transport) = client(listOf(response("/member/account/leave/prepare", prepareReply()), response("/member/account/leave/submit", leftReply())))
        val prepared = service.prepare()
        service.submit(prepared, assertionFor(prepared))
        assertEquals(listOf("/auth/session", "/member/account/leave/prepare", "/member/account/leave/submit"), transport.requests.map { it.path })
        val submitBody = MemberLeaveWire.objectOf(transport.requests.last().body!!)
        assertEquals(prepared.id, submitBody.getValue("preparation").jsonPrimitive.content)
    }

    @Test fun `submit surfaces a 409 as blocked and keeps the local session`() = runBlocking {
        val (service, sessions) = clientWithSessions(listOf(response("/member/account/leave/prepare", prepareReply()), response("/member/account/leave/submit", blockedReply(), 409)))
        val prepared = service.prepare()
        val failure = assertThrows(MemberLeaveBlockedException::class.java) { runBlocking { service.submit(prepared, assertionFor(prepared)) } }
        assertEquals(listOf("offer_in_progress", "a_future_kind_this_build_does_not_know"), failure.blockers.map { it.kind })
        // The review was spent, but nothing was deleted: the local session must still be usable.
        assertEquals(info, sessions.activeInfo())
    }

    @Test fun `an assertion signed for the wrong credential is refused before it is sent`() = runBlocking {
        val (service, _) = client(listOf(response("/member/account/leave/prepare", prepareReply())))
        val prepared = service.prepare()
        val wrongCredential = prepared.copy(credentialId = "other")
        assertThrows(MemberFailure.ScopeMismatch::class.java) { runBlocking { service.submit(prepared, assertionFor(wrongCredential)) } }
        Unit
    }

    @Test fun `export keeps node and privateRecords byte exact`() = runBlocking {
        // Deliberately odd formatting (key order, a trailing zero, nested whitespace) that a
        // decode/re-encode round trip would not reproduce, to prove the raw slice is kept.
        val nodeRaw = """{"b":1,"a":2.50,"c":[1,2,3]}"""
        val recordsRaw = """[{"id":"x","revision":1}]"""
        val text = """{"profile":"atarasy.member-export.1","household":"$household","exportedAt":1800000000600,"node":$nodeRaw,"privateRecords":$recordsRaw}"""
        val (service, _) = client(listOf(MemberHttpResponse(environment.origin + "/member/account/export", environment.origin + "/member/account/export", 200, "application/json", "no-store", text.toByteArray())))
        val export = service.export()
        assertEquals(household, export.household); assertEquals(1_800_000_000_600L, export.exportedAt)
        assertEquals(nodeRaw, export.node); assertEquals(recordsRaw, export.privateRecords)
        val rebuilt = String(export.fileContents(), Charsets.UTF_8)
        assertEquals(text, rebuilt)
    }

    @Test fun `an unrecognised top level key on the status route is refused`() = runBlocking {
        val (service, _) = client(listOf(response("/member/account/leave", buildJsonObject { put("profile", JsonPrimitive("atarasy.member-leave-status.1")); put("household", JsonPrimitive(household)); put("blockers", buildJsonArray {}); put("extra", JsonPrimitive("x")) })))
        assertThrows(MemberFailure.Malformed::class.java) { runBlocking { service.status() } }
        Unit
    }

    @Test fun `a status reply scoped to a different household is refused`() = runBlocking {
        val (service, _) = client(listOf(response("/member/account/leave", buildJsonObject { put("profile", JsonPrimitive("atarasy.member-leave-status.1")); put("household", JsonPrimitive("key:" + "B".repeat(43))); put("blockers", buildJsonArray {}) })))
        assertThrows(MemberFailure.ScopeMismatch::class.java) { runBlocking { service.status() } }
        Unit
    }

    @Test fun `a prepare reply for a different origin is refused`() = runBlocking {
        val bad = buildJsonObject {
            put("profile", JsonPrimitive("atarasy.member-leave.1")); put("id", JsonPrimitive("33333333-3333-4333-8333-333333333333")); put("household", JsonPrimitive(household))
            put("origin", JsonPrimitive("https://not-this-origin.example")); put("rpID", JsonPrimitive(environment.relyingPartyId)); put("expiresAt", JsonPrimitive(1_800_000_001_000)); put("digest", JsonPrimitive(digest))
            put("publicKey", buildJsonObject {
                put("challenge", JsonPrimitive(digest)); put("rpId", JsonPrimitive(environment.relyingPartyId)); put("timeout", JsonPrimitive(1_000)); put("userVerification", JsonPrimitive("required"))
                put("allowCredentials", buildJsonArray { add(buildJsonObject { put("type", JsonPrimitive("public-key")); put("id", JsonPrimitive(credential)) }) })
            })
        }
        val (service, _) = client(listOf(response("/member/account/leave/prepare", bad)))
        assertThrows(MemberFailure.ScopeMismatch::class.java) { runBlocking { service.prepare() } }
        Unit
    }

    @Test fun `a blocked reply with an empty blocker id is refused`() = runBlocking {
        val bad = buildJsonObject { put("error", JsonPrimitive("leave_blocked")); put("blockers", buildJsonArray { add(buildJsonObject { put("kind", JsonPrimitive("offer_in_progress")); put("id", JsonPrimitive("")) }) }) }
        val (service, _) = client(listOf(response("/member/account/leave/prepare", bad, 409)))
        assertThrows(MemberFailure.Malformed::class.java) { runBlocking { service.prepare() } }
        Unit
    }

    // Separate helper that also hands back the MemberSessionClient, for the one test that
    // needs to confirm the session survived a 409.
    private fun clientWithSessions(replies: List<MemberHttpResponse>): Pair<MemberLeaveService, MemberSessionClient> {
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", sessionJson())) + replies))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession(token, info))) { 1_800_000_000_000 }
        runBlocking { sessions.restore(household) }
        return MemberLeaveService(environment, sessions, now = { 1_800_000_000_000 }) to sessions
    }
}
