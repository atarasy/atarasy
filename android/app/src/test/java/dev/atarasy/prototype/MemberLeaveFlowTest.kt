package dev.atarasy.prototype

import java.util.Base64
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

private class InertPrivateNodeVault : MemberPrivateNodeKeyVault {
    override fun load(scope: String): ByteArray? = throw AssertionError("not used by lock()")
    override fun create(scope: String): ByteArray = throw AssertionError("not used by lock()")
    override fun install(scope: String, key: ByteArray) = throw AssertionError("not used by lock()")
}

private class ScriptedPasskeyAuthorizer(private val result: PasskeyResult) : PasskeyAuthorizer {
    var calls = 0; private set
    override suspend fun authenticate(serverRequestJson: String): PasskeyResult { calls++; return result }
}

class MemberLeaveFlowTest {
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
    private fun statusReply(blocked: Boolean) = buildJsonObject {
        put("profile", JsonPrimitive("atarasy.member-leave-status.1")); put("household", JsonPrimitive(household))
        put("blockers", buildJsonArray { if (blocked) add(buildJsonObject { put("kind", JsonPrimitive("offer_in_progress")); put("id", JsonPrimitive("11111111-1111-4111-8111-111111111111")) }) })
    }
    private fun prepareReply() = buildJsonObject {
        put("profile", JsonPrimitive("atarasy.member-leave.1")); put("id", JsonPrimitive("33333333-3333-4333-8333-333333333333")); put("household", JsonPrimitive(household))
        put("origin", JsonPrimitive(environment.origin)); put("rpID", JsonPrimitive(environment.relyingPartyId)); put("expiresAt", JsonPrimitive(1_800_000_001_000)); put("digest", JsonPrimitive(digest))
        put("publicKey", buildJsonObject {
            put("challenge", JsonPrimitive(digest)); put("rpId", JsonPrimitive(environment.relyingPartyId)); put("timeout", JsonPrimitive(1_000)); put("userVerification", JsonPrimitive("required"))
            put("allowCredentials", buildJsonArray { add(buildJsonObject { put("type", JsonPrimitive("public-key")); put("id", JsonPrimitive(credential)) }) })
        })
    }
    private fun blockedReply() = buildJsonObject {
        put("error", JsonPrimitive("leave_blocked"))
        put("blockers", buildJsonArray { add(buildJsonObject { put("kind", JsonPrimitive("statement_unsigned")); put("id", JsonPrimitive("22222222-2222-4222-8222-222222222222")) }) })
    }
    private fun leftReply() = buildJsonObject {
        put("profile", JsonPrimitive("atarasy.member-left.1")); put("household", JsonPrimitive(household)); put("leftAt", JsonPrimitive(1_800_000_000_500))
        put("deleted", buildJsonObject { put("offers", JsonPrimitive(0)) })
    }
    private fun assertionJson() = buildJsonObject {
        val clientData = buildJsonObject { put("type", JsonPrimitive("webauthn.get")); put("challenge", JsonPrimitive(digest)); put("origin", JsonPrimitive(environment.origin)) }
        put("id", JsonPrimitive(credential)); put("rawId", JsonPrimitive(credential)); put("type", JsonPrimitive("public-key"))
        put("response", buildJsonObject {
            put("clientDataJSON", JsonPrimitive(Base64.getUrlEncoder().withoutPadding().encodeToString(clientData.toString().toByteArray())))
            put("authenticatorData", JsonPrimitive("YQ")); put("signature", JsonPrimitive("YQ")); put("userHandle", kotlinx.serialization.json.JsonNull)
        })
    }.toString()

    /** §14.3: the device's journal, so a test can see it cleared. */
    private class RecordingOperations : MemberOperationStore {
        val cleared = mutableListOf<String>()
        override fun save(handle: MemberOperationHandle) {}
        override fun load(id: String): MemberOperationHandle? = null
        override fun handles(): List<MemberOperationHandle> = emptyList()
        override fun claim(handle: MemberOperationHandle, signature: String) {}
        override fun removeAll(household: String) { cleared.add(household) }
    }

    private fun flow(replies: List<MemberHttpResponse>, passkeys: PasskeyAuthorizer, operations: MemberOperationStore? = null): Pair<MemberLeaveFlow, MemberSessionClient> {
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", sessionJson())) + replies))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession(token, info))) { 1_800_000_000_000 }
        runBlocking { sessions.restore(household) }
        val service = MemberLeaveService(environment, sessions, now = { 1_800_000_000_000 })
        val privateNode = MemberPrivateNode(environment, MemberPrivateNodeRemote(sessions), InertPrivateNodeVault())
        val flow = MemberLeaveFlow(service, sessions, privateNode, passkeys, operations)
        flow.setSession(info)
        return flow to sessions
    }

    @Test fun `deleteAccount clears the local session on success`() = runBlocking {
        val (flow, sessions) = flow(listOf(response("/member/account/leave", statusReply(blocked = false)), response("/member/account/leave/prepare", prepareReply()), response("/member/account/leave/submit", leftReply())), ScriptedPasskeyAuthorizer(PasskeyResult.Completed(assertionJson())))
        assertEquals(MemberLeavePhase.READY, flow.refreshStatus().phase)
        val result = flow.deleteAccount()
        assertEquals(MemberLeavePhase.DONE, result.phase)
        assertEquals(household, result.result?.household)
        assertThrows(MemberFailure.Expired::class.java) { runBlocking { sessions.activeInfo() } }
        // A second call is inert: the flow's own session was cleared, and it is no longer READY.
        assertEquals(MemberLeavePhase.DONE, flow.deleteAccount().phase)
    }

    @Test fun `deleteAccount clears the device's own journal of that household`() = runBlocking {
        val operations = RecordingOperations()
        val (flow, _) = flow(listOf(response("/member/account/leave", statusReply(blocked = false)), response("/member/account/leave/prepare", prepareReply()), response("/member/account/leave/submit", leftReply())), ScriptedPasskeyAuthorizer(PasskeyResult.Completed(assertionJson())), operations)
        assertEquals(MemberLeavePhase.READY, flow.refreshStatus().phase)
        assertEquals(MemberLeavePhase.DONE, flow.deleteAccount().phase)
        assertEquals(listOf(household), operations.cleared)
    }

    @Test fun `deleteAccount keeps the local session when submit reports a blocker`() = runBlocking {
        val (flow, sessions) = flow(listOf(response("/member/account/leave", statusReply(blocked = false)), response("/member/account/leave/prepare", prepareReply()), response("/member/account/leave/submit", blockedReply(), 409)), ScriptedPasskeyAuthorizer(PasskeyResult.Completed(assertionJson())))
        assertEquals(MemberLeavePhase.READY, flow.refreshStatus().phase)
        val result = flow.deleteAccount()
        assertEquals(MemberLeavePhase.BLOCKED, result.phase)
        assertEquals(listOf("statement_unsigned"), result.blockers.map { it.kind })
        assertEquals(info, sessions.activeInfo())
    }

    @Test fun `refreshStatus reports blockers without touching the session`() = runBlocking {
        val (flow, sessions) = flow(listOf(response("/member/account/leave", statusReply(blocked = true))), ScriptedPasskeyAuthorizer(PasskeyResult.Unavailable))
        val result = flow.refreshStatus()
        assertEquals(MemberLeavePhase.BLOCKED, result.phase)
        assertEquals(listOf("offer_in_progress"), result.blockers.map { it.kind })
        assertEquals(info, sessions.activeInfo())
    }

    @Test fun `deleteAccount is a no-op outside the ready phase`() = runBlocking {
        val (flow, sessions) = flow(emptyList(), ScriptedPasskeyAuthorizer(PasskeyResult.Unavailable))
        // Never moved to READY: refreshStatus was never called.
        val result = flow.deleteAccount()
        assertEquals(MemberLeavePhase.IDLE, result.phase)
        assertEquals(info, sessions.activeInfo())
    }

    @Test fun `setSession null resets the flow's state`() = runBlocking {
        val (flow, _) = flow(listOf(response("/member/account/leave", statusReply(blocked = false))), ScriptedPasskeyAuthorizer(PasskeyResult.Unavailable))
        assertEquals(MemberLeavePhase.READY, flow.refreshStatus().phase)
        flow.setSession(null)
        assertEquals(MemberLeavePhase.IDLE, flow.state.phase)
        // Gated on session again: refreshStatus is now inert.
        assertEquals(MemberLeavePhase.IDLE, flow.refreshStatus().phase)
    }
}
