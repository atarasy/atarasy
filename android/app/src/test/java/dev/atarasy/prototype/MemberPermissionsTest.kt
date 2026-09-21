package dev.atarasy.prototype

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MemberPermissionsTest {
    private val json = Json { ignoreUnknownKeys = false }
    private val permissions by lazy { json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-permissions-runtime.json")).readText()).jsonObject }
    private val requests by lazy { json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-permission-request-runtime.json")).readText()).jsonObject }
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private fun response(path: String, value: kotlinx.serialization.json.JsonElement) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", value.toString().toByteArray())
    private fun client(root: JsonObject, replies: List<MemberHttpResponse>, now: Long = 1_800_000_000_001): Pair<MemberPermissions, DecisionTransport> {
        val session = MemberSessionCodec.decodeSession(root.getValue("session").toString().toByteArray())
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", root.getValue("session"))) + replies))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { now }
        runBlocking { sessions.restore(session.household) }
        return MemberPermissions(sessions) { now } to transport
    }

    @Test fun `permission list and revocation preserve the original grant`() = runBlocking {
        val (service, transport) = client(permissions, listOf(
            response("/member/permissions/list", permissions.getValue("listed")),
            response("/member/permissions/revoke", permissions.getValue("revoked")),
            response("/member/permissions/list", permissions.getValue("after")),
        ))
        val listed = service.list(); assertEquals(2, listed.permissions.size)
        val revoked = service.revoke(listed.permissions.first()); assertTrue(revoked.sameGrant(listed.permissions.first())); assertNotNull(revoked.revokedAt)
        val after = service.list(); assertEquals(listed.permissions[1], after.permissions[1])
        assertEquals("{\"permission\":\"${listed.permissions.first().id}\"}", transport.requests[2].body!!.toString(Charsets.UTF_8))
    }

    @Test fun `foreign duplicate and changed permission rows fail closed`() {
        val listed = permissions.getValue("listed").jsonObject
        val foreign = JsonObject(listed.toMutableMap().also { it["household"] = JsonPrimitive("other") })
        assertThrows(MemberFailure.ScopeMismatch::class.java) { MemberPermissionCodec.list(foreign.toString().toByteArray(), permissions.getValue("session").jsonObject.getValue("household").jsonPrimitive.content) }
        val rows = listed.getValue("permissions") as JsonArray
        val duplicate = JsonObject(listed.toMutableMap().also { it["permissions"] = JsonArray(rows + rows.first()) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberPermissionCodec.list(duplicate.toString().toByteArray(), listed.getValue("household").jsonPrimitive.content) }
    }

    @Test fun `permission request digest and granted terms match captured protocol`() = runBlocking {
        val review = requests.getValue("review").jsonObject
        val id = review.getValue("terms").jsonObject.getValue("requestID").jsonPrimitive.content
        val (service, transport) = client(requests, listOf(
            response("/member/permissions/requests/$id", review),
            response("/member/permissions/requests/$id/grant", requests.getValue("granted")),
            response("/member/permissions/requests/$id", requests.getValue("revoked")),
        ))
        val checked = service.request(id)
        assertEquals(checked.digest, Canonical.digest(checked.terms.canonical()))
        val granted = service.decide(checked, true); assertEquals(listOf("duplicate_check"), granted.permission!!.scope)
        val reread = service.request(id); assertNotNull(reread.permission!!.revokedAt)
        assertEquals("{\"digest\":\"${checked.digest}\"}", transport.requests[2].body!!.toString(Charsets.UTF_8))
    }

    @Test fun `tampered request and duplicate request list are refused`() {
        val review = requests.getValue("review").jsonObject
        val terms = review.getValue("terms").jsonObject.toMutableMap().also { it["purpose"] = JsonPrimitive("Changed purpose") }
        val changed = JsonObject(review.toMutableMap().also { it["terms"] = JsonObject(terms) })
        val household = requests.getValue("session").jsonObject.getValue("household").jsonPrimitive.content
        assertThrows(MemberFailure.ScopeMismatch::class.java) { MemberPermissionCodec.request(changed, household) }
        val list = JsonObject(mapOf("household" to JsonPrimitive(household), "checkedAt" to JsonPrimitive(1_800_000_000_001), "requests" to JsonArray(listOf(review, review))))
        assertThrows(MemberFailure.Malformed::class.java) { MemberPermissionCodec.requests(list.toString().toByteArray(), household) }
    }
}
