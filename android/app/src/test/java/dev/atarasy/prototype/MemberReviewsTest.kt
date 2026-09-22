package dev.atarasy.prototype

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private class ReviewVault(private var value: StoredMemberSession?) : MemberSessionVault {
    override fun load(environment: MemberEnvironment, household: String) = value
    override fun save(environment: MemberEnvironment, session: StoredMemberSession) { value = session }
    override fun remove(environment: MemberEnvironment, household: String) { value = null }
}
private class ReviewTransport(private val replies: ArrayDeque<MemberHttpResponse>) : MemberHttpTransport {
    val requests = mutableListOf<MemberHttpRequest>()
    override suspend fun send(request: MemberHttpRequest): MemberHttpResponse { requests += request; return replies.removeFirst() }
}

class MemberReviewsTest {
    private val json = Json { ignoreUnknownKeys = false }
    private val root by lazy { json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-review-responses.json")).readText()).jsonObject }
    private fun value(name: String): JsonObject = root["cases"]!!.jsonArray.first { it.jsonObject["name"]!!.jsonPrimitive.content == name }.jsonObject["value"]!!.jsonObject
    private fun detail(binding: String): MemberOfferDetail {
        val body = value("$binding-detail")
        return MemberOfferCodec.detail(body.toString().toByteArray(), body["id"]!!.jsonPrimitive.content, "detail-house")
    }
    private fun changed(name: String, block: (MutableMap<String, JsonElement>) -> Unit): ByteArray = value(name).toMutableMap().also(block).let(::JsonObject).toString().toByteArray()
    /** Question 72. Sets or clears the first disclosure block's `contact` in a captured case. */
    private fun withContact(name: String, contact: JsonElement?): ByteArray = changed(name) { map ->
        val blocks = map.getValue("disclosures").jsonArray.mapIndexed { i, el ->
            val row = el.jsonObject.toMutableMap()
            if (i == 0) { if (contact != null) row["contact"] = contact else row.remove("contact") }
            JsonObject(row) as JsonElement
        }
        map["disclosures"] = JsonArray(blocks)
    }

    @Test fun `actual approval preserves deliberation exclusions and nil versus zero`() {
        val detail = detail("digital")
        val unknown = MemberReviewCodec.approval(value("digital-unknown-carriage").toString().toByteArray(), detail)
        val known = MemberReviewCodec.approval(value("digital-known-carriage").toString().toByteArray(), detail)
        assertNull(unknown.carriage); assertEquals(0L, known.carriage)
        assertEquals(2, known.candidates[0].alternatives.size)
        assertEquals("Existing supplies may already be sufficient.", known.candidates[0].argumentAgainst)
        assertEquals("auto_renewal", known.excluded.single().reason)
        assertEquals("tea-b", known.candidates[1].disclosure.product)
    }

    @Test fun `actual statement verifies gift amount carriage and challenge`() {
        val detail = detail("physical")
        val unknown = MemberReviewCodec.statement(value("physical-unknown-carriage").toString().toByteArray(), detail)
        val known = MemberReviewCodec.statement(value("physical-known-carriage").toString().toByteArray(), detail)
        assertNull(unknown.carriage); assertEquals(550L, known.carriage)
        assertEquals(listOf(3000L, 0L), known.lines.map { it.amount })
        assertTrue(unknown.challenge != known.challenge)
    }

    @Test fun `review refuses missing fields changed scope goods and challenge`() {
        val digital = detail("digital"); val physical = detail("physical")
        val bad = listOf(
            changed("digital-known-carriage") { it.remove("carriage") } to digital,
            changed("digital-known-carriage") { it["offer"] = JsonPrimitive("foreign") } to digital,
            changed("physical-known-carriage") { it["challenge"] = JsonPrimitive("A".repeat(43)) } to physical,
            changed("physical-known-carriage") { map ->
                val rows = map["lines"]!!.jsonArray.map { it.jsonObject }.toMutableList()
                rows[0] = JsonObject(rows[0].toMutableMap().also { it["unit_price"] = JsonPrimitive(999) })
                map["lines"] = kotlinx.serialization.json.JsonArray(rows)
            } to physical,
        )
        bad.forEach { (bytes, source) ->
            assertThrows(MemberFailure::class.java) { if (source.binding == "digital") MemberReviewCodec.approval(bytes, source) else MemberReviewCodec.statement(bytes, source) }
        }
    }

    /**
     * Question 72, decided 2026-09-22. Carried on the approval and the statement the
     * same way as the detail: absent by default (the captured fixtures predate the
     * field), and where present it must match the detail's own copy of the block
     * exactly, the same as any other changed field would be refused.
     */
    @Test fun `disclosure contact is carried and must match the detail`() {
        val contact = buildJsonObject { put("kind", JsonPrimitive("email")); put("value", JsonPrimitive("returns@maker-a.example")) }
        val mismatched = buildJsonObject { put("kind", JsonPrimitive("email")); put("value", JsonPrimitive("different@maker-a.example")) }
        for (binding in listOf("digital", "physical")) {
            val detailBytes = withContact("$binding-detail", contact)
            val detail = MemberOfferCodec.detail(detailBytes, value("$binding-detail")["id"]!!.jsonPrimitive.content, "detail-house")
            assertEquals(MemberDisclosureContact("email", "returns@maker-a.example"), detail.disclosures[0].contact)

            val reviewBytes = withContact("$binding-known-carriage", contact)
            val decodedContact = if (binding == "digital") MemberReviewCodec.approval(reviewBytes, detail).disclosures[0].contact
                                  else MemberReviewCodec.statement(reviewBytes, detail).disclosures[0].contact
            assertEquals(MemberDisclosureContact("email", "returns@maker-a.example"), decodedContact)

            val mismatchBytes = withContact("$binding-known-carriage", mismatched)
            assertThrows(MemberFailure::class.java) {
                if (binding == "digital") MemberReviewCodec.approval(mismatchBytes, detail) else MemberReviewCodec.statement(mismatchBytes, detail)
            }
        }
    }

    @Test fun `client selects approval and statement routes with scoped bearer reads`() = runBlocking {
        val environment = MemberEnvironment.create("test", "https://unit.example")
        for (binding in listOf("digital", "physical")) {
            val detail = detail(binding); val session = MemberSessionInfo("session", detail.household, listOf(detail.presenter), 2_000_000_000_000)
            fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())
            val sessionBody = """{"id":"session","household":"${detail.household}","presenters":["${detail.presenter}"],"expiresAt":2000000000000}"""
            val reviewPath = "/offers/${detail.id}/${if (binding == "digital") "approval" else "statement"}"
            val transport = ReviewTransport(ArrayDeque(listOf(response("/auth/session", sessionBody), response(reviewPath, value("$binding-known-carriage").toString()))))
            val sessions = MemberSessionClient(environment, transport, ReviewVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_000 }
            sessions.restore(detail.household)
            val review = MemberReviews(sessions).load(detail)
            assertEquals(reviewPath, transport.requests.last().path)
            assertEquals("amr1_" + "A".repeat(43), transport.requests.last().token)
            assertTrue(if (binding == "digital") review is MemberReview.Approval else review is MemberReview.Statement)
        }
    }

    @Test fun `settlement totals and authority are checked`() {
        val fixture = json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-operation-runtime.json")).readText()).jsonObject["committed"]!!.jsonObject["receipt"]!!.jsonObject
        val id = fixture["offer"]!!.jsonPrimitive.content
        val decoded = MemberSettlementCodec.decode(fixture.toString().toByteArray(), id)
        assertEquals(1200L, decoded.charged)
        assertThrows(MemberFailure.ScopeMismatch::class.java) { MemberSettlementCodec.decode(fixture.toString().toByteArray(), "foreign") }
        val changed = JsonObject(fixture.toMutableMap().also { it["charged"] = JsonPrimitive(1) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberSettlementCodec.decode(changed.toString().toByteArray(), id) }
    }
}
