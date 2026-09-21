package dev.atarasy.prototype

import java.util.Base64
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private class WithdrawalStore : MemberOperationStore {
    private val values = linkedMapOf<String, MemberOperationHandle>()
    override fun save(handle: MemberOperationHandle) { values[handle.id]?.let { if (it != handle) throw MemberFailure.Storage }; values.putIfAbsent(handle.id, handle) }
    override fun load(id: String) = values[id]
    override fun handles() = values.values.toList()
    override fun claim(handle: MemberOperationHandle, signature: String) {
        if (values[handle.id] != handle || handle.attempted) throw MemberFailure.Busy
        values[handle.id] = handle.claimed(signature)
    }
}

class MemberWithdrawalOperationTest {
    private val json = Json { ignoreUnknownKeys = false }
    private val root by lazy { json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-withdrawal-runtime.json")).readText()).jsonObject }
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val session by lazy { MemberSessionCodec.decodeSession(root.getValue("session").toString().toByteArray()) }
    private fun response(path: String, element: kotlinx.serialization.json.JsonElement, status: Int = 200) =
        MemberHttpResponse(environment.origin + path, environment.origin + path, status, "application/json", "no-store", element.toString().toByteArray())
    private fun original(): MemberOperationHandle {
        val prepared = root.getValue("decisionPrepared").jsonObject
        val result = root.getValue("decisionOutcome").jsonObject.getValue("decision").jsonObject.toMutableMap()
        result.remove("reminders_sent")
        val detail = MemberOfferCodec.detail(JsonObject(result).toString().toByteArray(), result.getValue("id").jsonPrimitive.content, session.household)
        val publicKey = prepared.getValue("publicKey").jsonObject
        return MemberOperationHandle(
            prepared.getValue("operationID").jsonPrimitive.content, MEMBER_DECISION_PROFILE, environment.name, environment.origin, session.id,
            session.household, detail.presenter, detail.id, prepared.getValue("canonical").jsonPrimitive.content,
            prepared.getValue("expiresAt").jsonPrimitive.content.toLong(), prepared.getValue("requestDigest").jsonPrimitive.content,
            prepared.getValue("reviewedRevision").jsonPrimitive.content, publicKey.getValue("challenge").jsonPrimitive.content,
            publicKey.getValue("allowCredentials").jsonArray.single().jsonObject.getValue("id").jsonPrimitive.content,
            attempted = true, confirmationFingerprint = "f".repeat(64), digitalTermsDigest = MemberDigitalTerms.digest(detail),
        )
    }
    private fun committedDecisionReview(): JsonObject = JsonObject(root.getValue("decisionPrepared").jsonObject.toMutableMap().also { it["operationState"] = JsonPrimitive("committed") })
    private fun services(extra: List<MemberHttpResponse>): Triple<MemberWithdrawalOperations, WithdrawalStore, DecisionTransport> {
        val original = original()
        val replies = arrayListOf(
            response("/auth/session", root.getValue("session")),
            response("/member/operations/${original.id}/outcome", root.getValue("decisionOutcome")),
            response("/member/operations/${original.id}", committedDecisionReview()),
            response("/member/withdrawals/prepare", root.getValue("withdrawalPrepared")),
        ) + extra
        val transport = DecisionTransport(ArrayDeque(replies))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_001 }
        runBlocking { sessions.restore(session.household) }
        val store = WithdrawalStore()
        val decisions = MemberDecisionOperations(environment, sessions, store, now = { 1_800_000_000_001 })
        return Triple(MemberWithdrawalOperations(environment, sessions, store, decisions, now = { 1_800_000_000_001 }), store, transport)
    }

    @Test fun `captured withdrawal freezes original decision and saves its lineage`() = runBlocking {
        val (operations, store, transport) = services(emptyList())
        val result = operations.prepare(original())
        assertEquals(MEMBER_WITHDRAWAL_PROFILE, result.handle.operationProfile)
        assertEquals(original().id, result.handle.withdrawalDecisionId)
        assertEquals(1L, result.handle.withdrawalNextIncarnation)
        assertEquals(1750L, result.frozen.total)
        assertEquals(result.handle, store.load(result.handle.id))
        assertEquals(listOf("/auth/session", "/member/operations/${original().id}/outcome", "/member/operations/${original().id}", "/member/withdrawals/prepare"), transport.requests.map { it.path })
    }

    @Test fun `changed withdrawal review is refused before it is saved`() = runBlocking {
        val prepared = root.getValue("withdrawalPrepared").jsonObject
        val review = prepared.getValue("review").jsonObject
        val decision = review.getValue("decisionReview").jsonObject.toMutableMap().also { it["total"] = JsonPrimitive(0) }
        val changedReview = JsonObject(review.toMutableMap().also { it["decisionReview"] = JsonObject(decision) })
        val changed = JsonObject(prepared.toMutableMap().also { it["review"] = changedReview })
        val original = original()
        val transport = DecisionTransport(ArrayDeque(listOf(
            response("/auth/session", root.getValue("session")), response("/member/operations/${original.id}/outcome", root.getValue("decisionOutcome")),
            response("/member/operations/${original.id}", committedDecisionReview()), response("/member/withdrawals/prepare", changed),
        )))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_001 }
        sessions.restore(session.household); val store = WithdrawalStore(); val decisions = MemberDecisionOperations(environment, sessions, store, now = { 1_800_000_000_001 })
        val operations = MemberWithdrawalOperations(environment, sessions, store, decisions, now = { 1_800_000_000_001 })
        assertThrows(MemberFailure.ScopeMismatch::class.java) { runBlocking { operations.prepare(original) } }
        assertTrue(store.handles().isEmpty())
        Unit
    }

    @Test fun `submit claims once and validates historical withdrawal`() = runBlocking {
        val preparedId = root.getValue("withdrawalPrepared").jsonObject.getValue("operationID").jsonPrimitive.content
        val (operations, store, transport) = services(listOf(response("/member/operations/$preparedId/submit", root.getValue("withdrawalOutcome"))))
        val result = operations.prepare(original()); val handle = result.handle
        val clientData = """{"type":"webauthn.get","challenge":"${handle.challenge}","origin":"${environment.origin}","crossOrigin":false}"""
        val signature = Base64.getUrlEncoder().withoutPadding().encodeToString("signature".toByteArray())
        val assertion = """{"id":"${handle.credentialId}","response":{"clientDataJSON":"${Base64.getUrlEncoder().withoutPadding().encodeToString(clientData.toByteArray())}","signature":"$signature"}}"""
        val outcome = operations.submit(handle, assertion)
        assertTrue(outcome is MemberWithdrawalOutcome.Recorded)
        assertTrue(store.load(handle.id)!!.attempted)
        assertThrows(MemberFailure.Busy::class.java) { runBlocking { operations.submit(handle, assertion) } }
        assertEquals(1, transport.requests.count { it.path.endsWith("/submit") })
        Unit
    }

    @Test fun `changed historical offer cannot masquerade as the withdrawal`() = runBlocking {
        val (operations, _, _) = services(emptyList()); val handle = operations.prepare(original()).handle
        val envelope = root.getValue("withdrawalOutcome").jsonObject
        val withdrawal = envelope.getValue("withdrawal").jsonObject
        val offer = withdrawal.getValue("offer").jsonObject.toMutableMap().also { it["state"] = JsonPrimitive("decided") }
        val changed = JsonObject(envelope.toMutableMap().also { it["withdrawal"] = JsonObject(withdrawal.toMutableMap().also { row -> row["offer"] = JsonObject(offer) }) })
        assertThrows(MemberFailure.ScopeMismatch::class.java) { operations.decodeOutcome(changed.toString().toByteArray(), handle) }
        assertFalse(handle.attempted)
    }

    @Test fun `flow rereads frozen withdrawal before opening passkey`() = runBlocking {
        val preparedId = root.getValue("withdrawalPrepared").jsonObject.getValue("operationID").jsonPrimitive.content
        val prepared = root.getValue("withdrawalPrepared").jsonObject
        val changedReview = JsonObject(prepared.getValue("review").jsonObject.toMutableMap().also { it["incarnation"] = JsonPrimitive(2) })
        val changed = JsonObject(prepared.toMutableMap().also { it["review"] = changedReview })
        val (operations, _, transport) = services(listOf(response("/member/operations/$preparedId", changed)))
        var passkeyCalls = 0
        val flow = MemberWithdrawalFlow(MemberSessionClient(environment, DecisionTransport(ArrayDeque()), DecisionVault(null)), operations, object : PasskeyAuthorizer {
            override suspend fun authenticate(serverRequestJson: String): PasskeyResult { passkeyCalls++; return PasskeyResult.Unavailable }
        }) { 1_800_000_000_001 }
        // Preparation uses the already authenticated client owned by operations; approve must reject the changed reread before passkey UI.
        val preparedResult = operations.prepare(original())
        val action = flow.approve(MemberWithdrawalReview(preparedResult.handle, preparedResult.prepared, preparedResult.frozen))
        assertTrue(action is MemberWithdrawalActionResult.Failed); assertEquals(0, passkeyCalls)
        assertEquals(0, transport.requests.count { it.path.endsWith("/submit") })
    }
}
