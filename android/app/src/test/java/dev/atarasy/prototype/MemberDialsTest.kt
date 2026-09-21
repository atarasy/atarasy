package dev.atarasy.prototype

import java.util.Base64
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MemberDialsTest {
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val household = "key:" + "H".repeat(43)
    private val session = MemberSessionInfo("session", household, listOf("merchant"), 5_000)
    private val before = Mandate("$household.1", household, 10_000, null, 3_600, emptyList(), 4_000, 1)
    private val after = Mandate(before.id, household, 0, 0, 60, emptyList(), 3_500, 2)
    private val id = "11111111-1111-4111-8111-111111111111"
    private fun change(state: String = "pending", signed: List<String> = emptyList(), updated: Long = 1_000) = buildJsonObject {
        put("id", JsonPrimitive(id)); put("before", MemberDialsCodec.mandateJson(before)); put("mandate", MemberDialsCodec.mandateJson(after))
        put("requiredSigners", JsonArray(listOf(JsonPrimitive(household)))); put("signedBy", JsonArray(signed.map(::JsonPrimitive)))
        put("state", JsonPrimitive(state)); put("createdAt", JsonPrimitive(1_000)); put("updatedAt", JsonPrimitive(updated))
    }
    private fun prepared() = JsonObject(change().toMutableMap() + ("publicKey" to buildJsonObject {
        put("challenge", JsonPrimitive(Canonical.challenge(Canonical.mandate(after, environment.relyingPartyId))))
        put("rpId", JsonPrimitive(environment.relyingPartyId)); put("userVerification", JsonPrimitive("required"))
        put("allowCredentials", JsonArray(listOf(buildJsonObject { put("type", JsonPrimitive("public-key")); put("id", JsonPrimitive("YQ")) })))
    }))
    private fun response(path: String, body: String, status: Int = 200) = MemberHttpResponse(environment.origin + path, environment.origin + path, status, "application/json", "no-store", body.toByteArray())
    private fun service(replies: List<MemberHttpResponse>): Pair<MemberDials, DecisionTransport> {
        val sessionBody = """{"id":"session","household":"$household","presenters":["merchant"],"expiresAt":5000}"""
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", sessionBody)) + replies))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 100 }
        runBlocking { sessions.restore(household) }
        return MemberDials(environment, sessions, now = { 100 }) to transport
    }
    private fun assertion(): String {
        val client = """{"type":"webauthn.get","origin":"${environment.origin}","challenge":"${Canonical.challenge(Canonical.mandate(after, environment.relyingPartyId))}"}"""
        return """{"id":"YQ","response":{"clientDataJSON":"${Base64.getUrlEncoder().withoutPadding().encodeToString(client.toByteArray())}","authenticatorData":"YQ","signature":"YQ"}}"""
    }

    @Test fun `effective Dials prepare and submit a fixed change once`() = runBlocking {
        val completed = change("effective", listOf(household), 1_001)
        val (service, transport) = service(listOf(
            response("/member/mandates/effective", """{"mandates":[${MemberDialsCodec.mandateJson(before)}]}"""),
            response("/member/mandates/changes", """{"changes":[]}"""),
            response("/member/mandates/changes", prepared().toString(), 201),
            response("/member/mandates/changes/$id/submit", completed.toString()),
        ))
        assertEquals(listOf(before), service.effective()); assertEquals(emptyList<MemberMandateChange>(), service.changes())
        val review = service.prepare(after); assertEquals(after, review.change.mandate)
        var serverRequest = ""
        val flow = MemberDialsFlow(service, object : PasskeyAuthorizer {
            override suspend fun authenticate(serverRequestJson: String): PasskeyResult { serverRequest = serverRequestJson; return PasskeyResult.Completed(assertion()) }
        })
        val action = flow.approve(review) as MemberDialsActionResult.Recorded
        assertEquals("effective", action.change.state); assertEquals(review.publicKeyJson, serverRequest)
        assertThrows(MemberFailure.ScopeMismatch::class.java) { runBlocking { service.submit(review, assertion()) } }
        assertEquals(listOf("/auth/session", "/member/mandates/effective", "/member/mandates/changes", "/member/mandates/changes", "/member/mandates/changes/$id/submit"), transport.requests.map { it.path })
        Unit
    }

    @Test fun `changed challenge and invalid signer sets are refused`() {
        val badKey = prepared().toMutableMap().also { map ->
            val key = map.getValue("publicKey").let { it as JsonObject }.toMutableMap(); key["challenge"] = JsonPrimitive("A".repeat(43)); map["publicKey"] = JsonObject(key)
        }
        assertThrows(MemberFailure.ScopeMismatch::class.java) { MemberDialsCodec.prepared(JsonObject(badKey).toString().toByteArray(), environment, session, 100) }
        val badChange = change().toMutableMap().also { it["requiredSigners"] = JsonArray(emptyList()) }
        assertThrows(MemberFailure.ScopeMismatch::class.java) { MemberDialsCodec.change(JsonObject(badChange), session) }
    }
}
