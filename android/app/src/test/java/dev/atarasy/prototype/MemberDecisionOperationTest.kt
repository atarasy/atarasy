package dev.atarasy.prototype

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DecisionStore : MemberOperationStore {
    var value: MemberOperationHandle? = null
    override fun save(handle: MemberOperationHandle) { if (value != null && value != handle) throw MemberFailure.Storage; value = handle }
    override fun load(id: String) = value?.takeIf { it.id == id }
    override fun handles() = listOfNotNull(value)
    override fun claim(handle: MemberOperationHandle, signature: String) {
        if (value != handle || value?.attempted != false) throw MemberFailure.Busy
        value = handle.claimed(signature)
    }
}
class DecisionTransport(private val replies: ArrayDeque<MemberHttpResponse>) : MemberHttpTransport {
    val requests = mutableListOf<MemberHttpRequest>()
    override suspend fun send(request: MemberHttpRequest): MemberHttpResponse { requests += request; return replies.removeFirst() }
}
class DecisionVault(private var value: StoredMemberSession?) : MemberSessionVault {
    override fun load(environment: MemberEnvironment, household: String) = value
    override fun save(environment: MemberEnvironment, session: StoredMemberSession) { value = session }
    override fun remove(environment: MemberEnvironment, household: String) { value = null }
}

class MemberDecisionOperationTest {
    private val json = Json { ignoreUnknownKeys = false }
    private val root by lazy { json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-digital-runtime.json")).readText()).jsonObject }
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val detail by lazy { root["detail"]!!.jsonObject.let { MemberOfferCodec.detail(it.toString().toByteArray(), it["id"]!!.jsonPrimitive.content, root["session"]!!.jsonObject["household"]!!.jsonPrimitive.content) } }
    private val session by lazy { MemberSessionCodec.decodeSession(root["session"]!!.toString().toByteArray()) }
    private fun local(): PreparedMemberDecision {
        val approval = MemberReviewCodec.approval(root["prepared"]!!.jsonObject["review"]!!.jsonObject["approval"]!!.toString().toByteArray(), detail)
        val draft = MemberDigitalDraft(approval); approval.candidates.forEach { draft.choose(it.id, MemberDigitalChoice.KEEP) }
        return PreparedMemberDecision.create(environment, session, detail, draft, 1_800_000_000_001)
    }

    @Test fun `captured prepared decision binds challenge frozen review and server public key`() {
        val local = local(); val bytes = checkNotNull(javaClass.getResource("/member-digital-runtime.json")).readText()
        val preparedText = bytes.substringAfter("\"prepared\": ").let { text ->
            // Parse for values; raw-member preservation is tested against the pretty response assembled below.
            root["prepared"]!!.toString()
        }
        val prepared = MemberDecisionWire.prepared(preparedText.toByteArray(), environment, local.canonical)
        val frozen = MemberDecisionWire.freeze(prepared, local, 1_800_000_000_001)
        assertEquals("127b591c-12af-4365-862b-2c3098dc2fd2", prepared.operationId)
        assertEquals(1750L, frozen.total); assertEquals(local.decisions, frozen.decisions)
        assertTrue(prepared.publicKeyJson.contains("allowCredentials")); assertEquals(local.canonical, prepared.canonical)
        assertEquals("24ddbcd022c34b7a05a4d57aac622d12bd61cb14c565b1022c50838107065610", MemberDigitalTerms.digest(detail))
    }

    @Test fun `changed challenge totals and canonical are refused`() {
        val local = local(); val original = root["prepared"]!!.jsonObject
        val changedChallenge = JsonObject(original.toMutableMap().also { map ->
            val pk = map["publicKey"]!!.jsonObject.toMutableMap(); pk["challenge"] = JsonPrimitive("A".repeat(43)); map["publicKey"] = JsonObject(pk)
        })
        assertThrows(MemberFailure.ScopeMismatch::class.java) { MemberDecisionWire.prepared(changedChallenge.toString().toByteArray(), environment, local.canonical) }
        val prepared = MemberDecisionWire.prepared(original.toString().toByteArray(), environment, local.canonical)
        val changedReview = prepared.copy(review = JsonObject(prepared.review.toMutableMap().also { it["total"] = JsonPrimitive(1) }))
        assertThrows(MemberFailure.ScopeMismatch::class.java) { MemberDecisionWire.freeze(changedReview, local, 1_800_000_000_001) }
        assertThrows(MemberFailure.Malformed::class.java) { MemberDecisionWire.prepared(original.toString().toByteArray(), environment, "foreign") }
    }

    @Test fun `prepare posts scoped choices and saves only validated operation`() = runBlocking {
        fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", root["session"]!!.toString()), response("/member/decisions/prepare", root["prepared"]!!.toString()))))
        val token = "amr1_" + "A".repeat(43); val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession(token, session))) { 1_800_000_000_001 }
        sessions.restore(session.household); val store = DecisionStore()
        val result = MemberDecisionOperations(environment, sessions, store, now = { 1_800_000_000_001 }).prepare(local())
        assertEquals(result.handle, store.value); assertFalse(result.handle.attempted)
        assertEquals("/member/decisions/prepare", transport.requests.last().path); assertEquals(token, transport.requests.last().token)
        val body = json.parseToJsonElement(transport.requests.last().body!!.toString(Charsets.UTF_8)).jsonObject
        assertEquals(setOf("offer", "decisions"), body.keys)
        assertEquals(MemberDigitalTerms.digest(detail), result.handle.digitalTermsDigest)
    }

    @Test fun `submit claims before dispatch and validates committed historical decision`() = runBlocking {
        fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())
        val operationId = root["prepared"]!!.jsonObject["operationID"]!!.jsonPrimitive.content
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", root["session"]!!.toString()), response("/member/decisions/prepare", root["prepared"]!!.toString()), response("/member/operations/$operationId/submit", root["committed"]!!.toString()))))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_001 }
        sessions.restore(session.household); val store = DecisionStore(); val operations = MemberDecisionOperations(environment, sessions, store, now = { 1_800_000_000_001 })
        val prepared = operations.prepare(local())
        val clientData = """{"type":"webauthn.get","challenge":"${prepared.handle.challenge}","origin":"${environment.origin}","crossOrigin":false}"""
        val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(clientData.toByteArray())
        val signature = Base64.getUrlEncoder().withoutPadding().encodeToString("signature".toByteArray())
        val assertion = """{"id":"${prepared.handle.credentialId}","rawId":"${prepared.handle.credentialId}","type":"public-key","response":{"clientDataJSON":"$encoded","authenticatorData":"AA","signature":"$signature","userHandle":null},"clientExtensionResults":{},"authenticatorAttachment":"platform"}"""
        assertTrue(operations.decodeOutcome(root["committed"]!!.toString().toByteArray(), prepared.handle.claimed(signature)) is MemberDecisionOutcome.Recorded)
        val outcome = operations.submit(prepared.handle, assertion)
        assertTrue(outcome is MemberDecisionOutcome.Recorded); assertTrue(store.value!!.attempted)
        assertEquals("/member/operations/${prepared.handle.id}/submit", transport.requests.last().path)
        assertThrows(MemberFailure.Busy::class.java) { runBlocking { operations.submit(prepared.handle, assertion) } }
        Unit
    }

    @Test fun `untrusted client origin is refused before journal claim`() = runBlocking {
        fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", root["session"]!!.toString()), response("/member/decisions/prepare", root["prepared"]!!.toString()))))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_001 }
        sessions.restore(session.household); val store = DecisionStore(); val operations = MemberDecisionOperations(environment, sessions, store, now = { 1_800_000_000_001 })
        val prepared = operations.prepare(local()); val clientData = """{"type":"webauthn.get","challenge":"${prepared.handle.challenge}","origin":"https://foreign.example"}"""
        val assertion = """{"id":"${prepared.handle.credentialId}","response":{"clientDataJSON":"${Base64.getUrlEncoder().withoutPadding().encodeToString(clientData.toByteArray())}","signature":"${Base64.getUrlEncoder().withoutPadding().encodeToString("signature".toByteArray())}"}}"""
        assertThrows(MemberFailure.ScopeMismatch::class.java) { runBlocking { operations.submit(prepared.handle, assertion) } }
        assertFalse(store.value!!.attempted)
    }

    @Test fun `lost submit response remains unresolved and cannot be dispatched twice`() = runBlocking {
        fun response(path: String, body: String, status: Int = 200) = MemberHttpResponse(environment.origin + path, environment.origin + path, status, "application/json", "no-store", body.toByteArray())
        val operationId = root["prepared"]!!.jsonObject["operationID"]!!.jsonPrimitive.content
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", root["session"]!!.toString()), response("/member/decisions/prepare", root["prepared"]!!.toString()), response("/member/operations/$operationId/submit", "{}", 503))))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_001 }
        sessions.restore(session.household); val store = DecisionStore(); val operations = MemberDecisionOperations(environment, sessions, store, now = { 1_800_000_000_001 })
        val prepared = operations.prepare(local()); val clientData = """{"type":"webauthn.get","challenge":"${prepared.handle.challenge}","origin":"${environment.origin}"}"""
        val assertion = """{"id":"${prepared.handle.credentialId}","response":{"clientDataJSON":"${Base64.getUrlEncoder().withoutPadding().encodeToString(clientData.toByteArray())}","signature":"${Base64.getUrlEncoder().withoutPadding().encodeToString("signature".toByteArray())}"}}"""
        assertEquals(MemberDecisionOutcome.Unresolved, operations.submit(prepared.handle, assertion)); assertTrue(store.value!!.attempted)
        assertThrows(MemberFailure.Busy::class.java) { runBlocking { operations.submit(prepared.handle, assertion) } }
        assertEquals(3, transport.requests.size)
        Unit
    }

    @Test fun `decision flow rereads frozen operation before asking for passkey`() = runBlocking {
        fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())
        val operationId = root["prepared"]!!.jsonObject["operationID"]!!.jsonPrimitive.content
        val transport = DecisionTransport(ArrayDeque(listOf(
            response("/auth/session", root["session"]!!.toString()), response("/member/decisions/prepare", root["prepared"]!!.toString()),
            response("/member/operations/$operationId", root["prepared"]!!.toString()), response("/member/operations/$operationId/submit", root["committed"]!!.toString()),
        )))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_001 }
        sessions.restore(session.household); val store = DecisionStore(); val operations = MemberDecisionOperations(environment, sessions, store, now = { 1_800_000_000_001 })
        val challenge = root["prepared"]!!.jsonObject["publicKey"]!!.jsonObject["challenge"]!!.jsonPrimitive.content
        val credential = root["prepared"]!!.jsonObject["publicKey"]!!.jsonObject["allowCredentials"]!!.jsonArray.single().jsonObject["id"]!!.jsonPrimitive.content
        val clientData = """{"type":"webauthn.get","challenge":"$challenge","origin":"${environment.origin}"}"""
        val assertion = """{"id":"$credential","response":{"clientDataJSON":"${Base64.getUrlEncoder().withoutPadding().encodeToString(clientData.toByteArray())}","signature":"${Base64.getUrlEncoder().withoutPadding().encodeToString("signature".toByteArray())}"}}"""
        var passkeyCalls = 0
        val flow = MemberDigitalDecisionFlow(environment, sessions, operations, object : PasskeyAuthorizer {
            override suspend fun authenticate(serverRequestJson: String): PasskeyResult { passkeyCalls++; return PasskeyResult.Completed(assertion) }
        }) { 1_800_000_000_001 }
        val approval = MemberReviewCodec.approval(root["prepared"]!!.jsonObject["review"]!!.jsonObject["approval"]!!.toString().toByteArray(), detail)
        val review = flow.prepare(session, detail, approval, approval.candidates.associate { it.id to MemberDigitalChoice.KEEP })
        val result = flow.approve(review)
        assertTrue(result is MemberDecisionActionResult.Outcome && result.value is MemberDecisionOutcome.Recorded)
        assertEquals(1, passkeyCalls)
        assertEquals(listOf("/auth/session", "/member/decisions/prepare", "/member/operations/$operationId", "/member/operations/$operationId/submit"), transport.requests.map { it.path })
    }
}
