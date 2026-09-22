package dev.atarasy.prototype

import java.util.Base64
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MemberStatementOperationTest {
    private val json = Json { ignoreUnknownKeys = false }
    private val root by lazy { json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-operation-runtime.json")).readText()).jsonObject }
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val preparedJson get() = root["prepared"]!!.jsonObject
    private val statementJson get() = preparedJson["review"]!!.jsonObject["statement"]!!.jsonObject
    private val session = MemberSessionInfo("session", "house", listOf("merchant-1"), 1_800_000_010_000)
    private val detail by lazy {
        val row = statementJson["lines"]!!.jsonArray.single().jsonObject
        val disclosures = statementJson["disclosures"]!!.jsonArray.map { block ->
            val d = block.jsonObject
            MemberDisclosure(d["merchant"]!!.jsonPrimitive.content, d["product"]?.takeUnless { it is kotlinx.serialization.json.JsonNull }?.jsonPrimitive?.content, d["version"]!!.jsonPrimitive.content,
                d["items"]!!.jsonArray.map { item -> MemberDisclosureItem(item.jsonObject["label"]!!.jsonPrimitive.content, item.jsonObject["value"]!!.jsonPrimitive.content) }, d["signature"]!!.jsonPrimitive.content,
                // The captured fixture predates question 72; the row carries none.
                null)
        }
        MemberOfferDetail(
            statementJson["offer"]!!.jsonPrimitive.content, "physical", "house", "merchant-1", true, "replenish", null, null, "cfg", 1_800_000_000_000,
            statementJson["expires_at"]!!.jsonPrimitive.content.toLong(), "decided", 1_800_000_000_001, true, "mandate-1",
            listOf(MemberCandidate(row["candidate"]!!.jsonPrimitive.content, row["product"]!!.jsonPrimitive.content, row["quantity"]!!.jsonPrimitive.content.toLong(), row["unit_price"]!!.jsonPrimitive.content.toLong(), row["merchant"]!!.jsonPrimitive.content, row["maker"]!!.jsonPrimitive.content, row["ships"]!!.jsonPrimitive.content, null, null, false, null, "consumed", 1_800_000_000_001, null, null, null)),
            disclosures, false,
        )
    }
    private val statement by lazy {
        val withChallenge = kotlinx.serialization.json.JsonObject(statementJson + ("challenge" to kotlinx.serialization.json.JsonPrimitive(Canonical.challenge(preparedJson["canonical"]!!.jsonPrimitive.content))))
        MemberReviewCodec.statement(withChallenge.toString().toByteArray(), detail)
    }
    private val local by lazy { PreparedMemberStatement.create(environment, session, detail, statement, emptyList(), 1_800_000_000_003) }

    @Test fun `physical statement preparation reproduces captured canonical and challenge`() {
        assertEquals(preparedJson["canonical"]!!.jsonPrimitive.content, local.canonical)
        assertEquals(1200L, local.goodsCharged); assertEquals(0L, local.disputedGoods); assertEquals(550L, local.carriage)
        assertEquals(Canonical.challenge(local.canonical), local.challenge)
    }

    @Test fun `prepared statement validates frozen statement and operation envelope`() {
        val prepared = MemberStatementWire.prepared(preparedJson.toString().toByteArray(), environment, local, detail)
        assertEquals("688d06f8-3a27-4899-983d-67314336a8ec", prepared.operationId)
        assertEquals("_t01RlUXclHrfxqsAD_wH0bJjXRVhjgax1jKq0SnsFI", prepared.challenge)
        assertThrows(MemberFailure.Malformed::class.java) { MemberStatementWire.prepared(preparedJson.toString().toByteArray(), environment, local.copy(canonical = "changed"), detail) }
    }

    @Test fun `statement client prepares submits once and verifies matching receipt confirmation`() = runBlocking {
        fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())
        val id = preparedJson["operationID"]!!.jsonPrimitive.content
        val sessionBody = """{"id":"session","household":"house","presenters":["merchant-1"],"expiresAt":1800000010000}"""
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", sessionBody), response("/member/statements/prepare", preparedJson.toString()), response("/member/operations/$id/submit", root["committed"]!!.toString()))))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_003 }
        sessions.restore("house"); val store = DecisionStore(); val operations = MemberStatementOperations(environment, sessions, store, now = { 1_800_000_000_003 })
        val (handle, _) = operations.prepare(local, detail)
        val clientData = """{"type":"webauthn.get","challenge":"${handle.challenge}","origin":"${environment.origin}"}"""; val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(clientData.toByteArray())
        val signature = root["committed"]!!.jsonObject["receipt"]!!.jsonObject["confirmation"]!!.jsonPrimitive.content
        val assertion = """{"id":"${handle.credentialId}","response":{"clientDataJSON":"$encoded","signature":"$signature"}}"""
        val result = operations.submit(handle, assertion)
        assertTrue(result is MemberStatementOutcome.Committed); assertTrue(store.value!!.attempted)
        assertThrows(MemberFailure.Busy::class.java) { runBlocking { operations.submit(handle, assertion) } }
        Unit
    }

    @Test fun `unattempted matching settlement is never attributed to this device`() {
        val p = MemberStatementWire.prepared(preparedJson.toString().toByteArray(), environment, local, detail)
        val handle = MemberOperationHandle(p.operationId, MEMBER_STATEMENT_PROFILE, environment.name, environment.origin, session.id, session.household, detail.presenter, detail.id, local.canonical, p.expiresAt, p.requestDigest, p.reviewedRevision, p.challenge, p.credentialId)
        val operations = MemberStatementOperations(environment, MemberSessionClient(environment, DecisionTransport(ArrayDeque()), DecisionVault(null)), DecisionStore())
        assertTrue(operations.decodeOutcome(root["committed"]!!.toString().toByteArray(), handle) is MemberStatementOutcome.SettledElsewhere)
    }
}
