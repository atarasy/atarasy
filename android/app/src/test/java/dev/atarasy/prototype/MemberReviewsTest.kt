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

    // §6.6, question 70.
    private fun correctionsBody(offer: String = "fixture-offer", net: Long = 800L, carriage: JsonElement = JsonPrimitive(0L)): JsonObject = buildJsonObject {
        put("offer", JsonPrimitive(offer))
        put("original", buildJsonObject { put("charged", JsonPrimitive(1200L)); put("carriage", carriage) })
        put("corrections", JsonArray(listOf(buildJsonObject {
            put("id", JsonPrimitive("correction-1")); put("offer", JsonPrimitive(offer)); put("merchant", JsonPrimitive("maker-a"))
            put("amount", JsonPrimitive(400L)); put("kind", JsonPrimitive("refund")); put("note", JsonPrimitive("One bottle arrived broken."))
            put("corrected_at", JsonPrimitive(2000L)); put("signature", JsonPrimitive("sig-1"))
        })))
        put("net", JsonPrimitive(net))
    }
    private fun settledDetail(offerId: String, household: String = "house"): MemberOfferDetail {
        val base = value("physical-detail").toMutableMap()
        base["id"] = JsonPrimitive(offerId); base["household"] = JsonPrimitive(household); base["state"] = JsonPrimitive("settled")
        return MemberOfferCodec.detail(JsonObject(base).toString().toByteArray(), offerId, household)
    }

    @Test fun `corrections decode the original each correction and the net`() {
        val decoded = MemberCorrectionsCodec.decode(correctionsBody().toString().toByteArray(), "fixture-offer")
        assertEquals(1200L, decoded.original.charged); assertEquals(0L, decoded.original.carriage)
        assertEquals(800L, decoded.net); assertEquals(1, decoded.corrections.size)
        assertEquals("refund", decoded.corrections[0].kind); assertEquals("One bottle arrived broken.", decoded.corrections[0].note)
        // A null carriage decodes as nil, distinct from a recorded zero.
        val unknown = MemberCorrectionsCodec.decode(correctionsBody(carriage = kotlinx.serialization.json.JsonNull).toString().toByteArray(), "fixture-offer")
        assertNull(unknown.original.carriage)
    }

    @Test fun `corrections with mismatched arithmetic are refused`() {
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(correctionsBody(net = 799L).toString().toByteArray(), "fixture-offer") }
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(correctionsBody(net = 801L).toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `corrections with an extra field anywhere are refused`() {
        val extraRoot = JsonObject(correctionsBody().toMutableMap().also { it["paid"] = JsonPrimitive(true) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(extraRoot.toString().toByteArray(), "fixture-offer") }
        val body = correctionsBody()
        val rows = body["corrections"]!!.jsonArray.map { it.jsonObject.toMutableMap().also { r -> r["extra"] = JsonPrimitive("no") } }.map { JsonObject(it) as JsonElement }
        val extraRow = JsonObject(body.toMutableMap().also { it["corrections"] = JsonArray(rows) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(extraRow.toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `a correction naming another offer, or a body naming another offer, is refused`() {
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(correctionsBody().toString().toByteArray(), "another-offer") }
        val body = correctionsBody()
        val rows = body["corrections"]!!.jsonArray.map { it.jsonObject.toMutableMap().also { r -> r["offer"] = JsonPrimitive("another-offer") } }.map { JsonObject(it) as JsonElement }
        val wrongRow = JsonObject(body.toMutableMap().also { it["corrections"] = JsonArray(rows) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(wrongRow.toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `a correction of zero, or a sum exceeding what was charged, is refused`() {
        val body = correctionsBody()
        val zeroRows = body["corrections"]!!.jsonArray.map { it.jsonObject.toMutableMap().also { r -> r["amount"] = JsonPrimitive(0L) } }.map { JsonObject(it) as JsonElement }
        val zero = JsonObject(body.toMutableMap().also { it["corrections"] = JsonArray(zeroRows); it["net"] = JsonPrimitive(1200L) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(zero.toString().toByteArray(), "fixture-offer") }
        val overRows = body["corrections"]!!.jsonArray.map { it.jsonObject.toMutableMap().also { r -> r["amount"] = JsonPrimitive(2000L) } }.map { JsonObject(it) as JsonElement }
        val over = JsonObject(body.toMutableMap().also { it["corrections"] = JsonArray(overRows); it["net"] = JsonPrimitive(-800L) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(over.toString().toByteArray(), "fixture-offer") }
    }

    /**
     * §6.6, question 70. `MemberReviews.load()` reads the corrections beside a
     * settlement and never in its place.
     */
    @Test fun `client reads corrections beside a settled offer`() = runBlocking {
        val environment = MemberEnvironment.create("test", "https://unit.example")
        val fixture = json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-operation-runtime.json")).readText()).jsonObject["committed"]!!.jsonObject["receipt"]!!.jsonObject
        val offerId = fixture["offer"]!!.jsonPrimitive.content
        val detail = settledDetail(offerId)
        val session = MemberSessionInfo("session", detail.household, listOf(detail.presenter), 2_000_000_000_000)
        fun response(path: String, body: String, status: Int = 200) = MemberHttpResponse(environment.origin + path, environment.origin + path, status, "application/json", "no-store", body.toByteArray())
        val sessionBody = """{"id":"session","household":"${detail.household}","presenters":["${detail.presenter}"],"expiresAt":2000000000000}"""
        val transport = ReviewTransport(ArrayDeque(listOf(
            response("/auth/session", sessionBody),
            response("/offers/$offerId/settlement", fixture.toString()),
            response("/offers/$offerId/corrections", correctionsBody(offer = offerId).toString()),
        )))
        val sessions = MemberSessionClient(environment, transport, ReviewVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_000 }
        sessions.restore(detail.household)
        val review = MemberReviews(sessions).load(detail) as MemberReview.Settlement
        assertEquals(1200L, review.value.charged)
        assertEquals("/offers/$offerId/corrections", transport.requests.last().path)
        assertEquals(800L, review.corrections?.net)
        assertEquals(1, review.corrections?.corrections?.size)
        assertEquals("One bottle arrived broken.", review.corrections?.corrections?.get(0)?.note)
    }

    /**
     * A 404 (the offer has no settlement, which cannot arise once the
     * settlement itself was read) or a malformed corrections body is
     * swallowed: the settlement it stands beside must remain readable.
     */
    @Test fun `a failed corrections read never hides the settlement`() = runBlocking {
        val environment = MemberEnvironment.create("test", "https://unit.example")
        val fixture = json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-operation-runtime.json")).readText()).jsonObject["committed"]!!.jsonObject["receipt"]!!.jsonObject
        val offerId = fixture["offer"]!!.jsonPrimitive.content
        val detail = settledDetail(offerId)
        val session = MemberSessionInfo("session", detail.household, listOf(detail.presenter), 2_000_000_000_000)
        fun response(path: String, body: String, status: Int = 200) = MemberHttpResponse(environment.origin + path, environment.origin + path, status, "application/json", "no-store", body.toByteArray())
        val sessionBody = """{"id":"session","household":"${detail.household}","presenters":["${detail.presenter}"],"expiresAt":2000000000000}"""
        val transport = ReviewTransport(ArrayDeque(listOf(
            response("/auth/session", sessionBody),
            response("/offers/$offerId/settlement", fixture.toString()),
            response("/offers/$offerId/corrections", """{"error":"not_found","message":"no such offer"}""", status = 404),
        )))
        val sessions = MemberSessionClient(environment, transport, ReviewVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_000 }
        sessions.restore(detail.household)
        val review = MemberReviews(sessions).load(detail) as MemberReview.Settlement
        assertEquals(1200L, review.value.charged)
        assertNull(review.corrections)
    }

    // SPEC §6.6a.
    private fun returnRow(
        state: String = "returned", correction: String = "correction-1", offer: String = "fixture-offer",
        merchant: String = "maker-a", at: Long = 3000L, note: String = "The issuer bounced it.", signature: String = "sig-r1",
    ): JsonObject = buildJsonObject {
        put("correction", JsonPrimitive(correction)); put("offer", JsonPrimitive(offer)); put("merchant", JsonPrimitive(merchant))
        put("state", JsonPrimitive(state)); put("note", JsonPrimitive(note)); put("at", JsonPrimitive(at)); put("signature", JsonPrimitive(signature))
    }
    private fun withReturns(offer: String = "fixture-offer", net: Long = 800L, returns: List<JsonObject>, owed: Long): JsonObject =
        JsonObject(correctionsBody(offer, net).toMutableMap().also { it["returns"] = JsonArray(returns); it["owed"] = JsonPrimitive(owed) })

    @Test fun `both keys are absent where nothing was returned`() {
        val decoded = MemberCorrectionsCodec.decode(correctionsBody().toString().toByteArray(), "fixture-offer")
        assertNull(decoded.returns); assertNull(decoded.owed)
    }

    @Test fun `a returned refund decodes and owed sums it`() {
        val decoded = MemberCorrectionsCodec.decode(withReturns(returns = listOf(returnRow()), owed = 400L).toString().toByteArray(), "fixture-offer")
        assertEquals(1, decoded.returns?.size); assertEquals("returned", decoded.returns?.get(0)?.state); assertEquals(400L, decoded.owed)
    }

    @Test fun `a repaid return leaves nothing owed`() {
        val repaid = returnRow(state = "repaid", at = 4000L, note = "Sent by bank transfer.", signature = "sig-r2")
        val decoded = MemberCorrectionsCodec.decode(withReturns(returns = listOf(returnRow(), repaid), owed = 0L).toString().toByteArray(), "fixture-offer")
        assertEquals(2, decoded.returns?.size); assertEquals(0L, decoded.owed)
    }

    @Test fun `owed that does not match the sum of unpaid returns is refused`() {
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = listOf(returnRow()), owed = 0L).toString().toByteArray(), "fixture-offer") }
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = listOf(returnRow()), owed = 401L).toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `returns present without owed, or owed without returns, is refused`() {
        val returnsOnly = JsonObject(correctionsBody().toMutableMap().also { it["returns"] = JsonArray(listOf(returnRow())) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(returnsOnly.toString().toByteArray(), "fixture-offer") }
        val owedOnly = JsonObject(correctionsBody().toMutableMap().also { it["owed"] = JsonPrimitive(400L) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(owedOnly.toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `an empty returns array is refused rather than read as none`() {
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = emptyList(), owed = 0L).toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `a return naming a correction outside this receipt is refused`() {
        val stray = returnRow(correction = "correction-2")
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = listOf(stray), owed = 0L).toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `a return on a collection correction is refused`() {
        val body = correctionsBody()
        val rows = body["corrections"]!!.jsonArray.map { it.jsonObject.toMutableMap().also { r -> r["kind"] = JsonPrimitive("collection") } }.map { JsonObject(it) as JsonElement }
        val collectionBody = JsonObject(body.toMutableMap().also { it["corrections"] = JsonArray(rows); it["returns"] = JsonArray(listOf(returnRow())); it["owed"] = JsonPrimitive(400L) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(collectionBody.toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `a return whose merchant differs from the corrections is refused`() {
        val wrongMerchant = returnRow(merchant = "maker-b")
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = listOf(wrongMerchant), owed = 400L).toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `more than one returned, or a repaid with no returned, is refused`() {
        val twice = listOf(returnRow(), returnRow(at = 3500L, signature = "sig-r2"))
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = twice, owed = 400L).toString().toByteArray(), "fixture-offer") }
        val repaidAlone = listOf(returnRow(state = "repaid"))
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = repaidAlone, owed = 0L).toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `a repaid before its own returned, or a return before the correction, is refused`() {
        val repaidEarly = listOf(returnRow(), returnRow(state = "repaid", at = 2500L, signature = "sig-r2"))
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = repaidEarly, owed = 0L).toString().toByteArray(), "fixture-offer") }
        val beforeCorrection = listOf(returnRow(at = 1000L))
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = beforeCorrection, owed = 400L).toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `an extra field on a return row is refused`() {
        val extra = JsonObject(returnRow().toMutableMap().also { it["paid"] = JsonPrimitive(true) })
        assertThrows(MemberFailure.Malformed::class.java) { MemberCorrectionsCodec.decode(withReturns(returns = listOf(extra), owed = 400L).toString().toByteArray(), "fixture-offer") }
    }

    @Test fun `the shop's own words on a return pass through as plain text`() {
        val withMarkup = returnRow(note = "<b>sorry</b>, the bank bounced it")
        val decoded = MemberCorrectionsCodec.decode(withReturns(returns = listOf(withMarkup), owed = 400L).toString().toByteArray(), "fixture-offer")
        assertEquals("<b>sorry</b>, the bank bounced it", decoded.returns?.get(0)?.note)
    }

    /** SPEC §6.6a. A settled review carries a return beside its correction, and the offer's own disclosures. */
    @Test fun `client reads a return beside a settled offer, and carries the offer's disclosures`() = runBlocking {
        val environment = MemberEnvironment.create("test", "https://unit.example")
        val fixture = json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-operation-runtime.json")).readText()).jsonObject["committed"]!!.jsonObject["receipt"]!!.jsonObject
        val offerId = fixture["offer"]!!.jsonPrimitive.content
        val detail = settledDetail(offerId)
        val session = MemberSessionInfo("session", detail.household, listOf(detail.presenter), 2_000_000_000_000)
        fun response(path: String, body: String, status: Int = 200) = MemberHttpResponse(environment.origin + path, environment.origin + path, status, "application/json", "no-store", body.toByteArray())
        val sessionBody = """{"id":"session","household":"${detail.household}","presenters":["${detail.presenter}"],"expiresAt":2000000000000}"""
        val transport = ReviewTransport(ArrayDeque(listOf(
            response("/auth/session", sessionBody),
            response("/offers/$offerId/settlement", fixture.toString()),
            response("/offers/$offerId/corrections", withReturns(offer = offerId, returns = listOf(returnRow(offer = offerId)), owed = 400L).toString()),
        )))
        val sessions = MemberSessionClient(environment, transport, ReviewVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_000 }
        sessions.restore(detail.household)
        val review = MemberReviews(sessions).load(detail) as MemberReview.Settlement
        assertEquals(1, review.corrections?.returns?.size)
        assertEquals("returned", review.corrections?.returns?.get(0)?.state)
        assertEquals(400L, review.corrections?.owed)
        assertEquals(detail.disclosures, review.disclosures)
    }
}
