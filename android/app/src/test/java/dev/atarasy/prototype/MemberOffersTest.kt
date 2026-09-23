package dev.atarasy.prototype

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private class OfferVault(private var session: StoredMemberSession?) : MemberSessionVault {
    override fun load(environment: MemberEnvironment, household: String) = session
    override fun save(environment: MemberEnvironment, session: StoredMemberSession) { this.session = session }
    override fun remove(environment: MemberEnvironment, household: String) { session = null }
}

private class OfferTransport(
    private val environment: MemberEnvironment,
    private val replies: ArrayDeque<MemberHttpResponse>,
) : MemberHttpTransport {
    val requests = mutableListOf<MemberHttpRequest>()
    override suspend fun send(request: MemberHttpRequest): MemberHttpResponse {
        requests += request
        return replies.removeFirst()
    }
}

class MemberOffersTest {
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val token = "amr1_" + "A".repeat(43)
    private val session = MemberSessionInfo("session", "detail-house", listOf("merchant-1"), 2_000_000_000_000)
    private val fixture: JsonObject by lazy {
        val text = checkNotNull(javaClass.getResource("/member-detail-responses.json")).readText()
        Json.parseToJsonElement(text).jsonObject["cases"]!!.jsonArray[0].jsonObject["value"]!!.jsonObject
    }
    private fun response(path: String, body: String, status: Int = 200) = MemberHttpResponse(
        environment.origin + path, environment.origin + path, status, "application/json", "no-store", body.toByteArray(),
    )
    private fun sessionBody() = """{"id":"session","household":"detail-house","presenters":["merchant-1"],"expiresAt":2000000000000}"""
    private fun client(vararg replies: MemberHttpResponse): Pair<MemberOffers, OfferTransport> {
        val transport = OfferTransport(environment, ArrayDeque(replies.toList()))
        val sessions = MemberSessionClient(environment, transport, OfferVault(StoredMemberSession(token, session))) { 1_800_000_000_000 }
        runBlocking { sessions.restore(session.household) }
        return MemberOffers(sessions) to transport
    }
    private fun withSession(vararg replies: MemberHttpResponse): Pair<MemberOffers, OfferTransport> =
        client(response("/auth/session", sessionBody()), *replies)

    @Test fun `list uses exact scoped query and bearer authority`() = runBlocking {
        val body = """{"offers":[{"id":"offer-1","household":"detail-house","presenter":"merchant-1","binding":"digital","state":"presented"}]}"""
        val (offers, transport) = withSession(response("/offers", body))
        assertEquals("offer-1", offers.list("merchant-1").single().id)
        assertEquals(listOf("household" to "detail-house", "presenter" to "merchant-1"), transport.requests.last().query)
        assertEquals(token, transport.requests.last().token)
    }

    @Test fun `list rejects unknown shape foreign rows and unowned presenter`() = runBlocking {
        for (body in listOf(
            "[]",
            """{"offers":[],"extra":true}""",
            """{"offers":[{"id":"offer-1","household":"detail-house","presenter":"merchant-1","binding":"digital","state":"presented"},{"id":"offer-1","household":"detail-house","presenter":"merchant-1","binding":"digital","state":"presented"}]}""",
            """{"offers":[{"id":"offer-1","household":"foreign","presenter":"merchant-1","binding":"digital","state":"presented"}]}""",
            """{"offers":[{"id":"offer-1","household":"detail-house","presenter":"merchant-1","binding":"other","state":"presented"}]}""",
        )) {
            val (offers, _) = withSession(response("/offers", body))
            assertThrows(MemberFailure::class.java) { runBlocking { offers.list("merchant-1") } }
        }
        val (offers, transport) = withSession()
        assertThrows(MemberFailure.ScopeMismatch::class.java) { runBlocking { offers.list("foreign") } }
        assertEquals(1, transport.requests.size)
    }

    @Test fun `captured detail preserves candidates disclosures and optional collection verdict`() = runBlocking {
        val id = fixture["id"]!!.jsonPrimitive.content
        val (offers, transport) = withSession(response("/offers/$id", fixture.toString()))
        val value = offers.detail(id)
        assertEquals(2, value.candidates.size)
        assertEquals(1200, value.candidates[0].unitPrice)
        assertEquals(listOf("payment", "delivery", "returns"), value.disclosures.single().items.map { it.label })
        assertTrue(!value.collectedAsSupplied)
        assertEquals("/offers/$id", transport.requests.last().path)
    }

    @Test fun `selected summary binds detail presenter and binding`() = runBlocking {
        val id = fixture["id"]!!.jsonPrimitive.content
        for (summary in listOf(
            MemberOfferSummary(id, "detail-house", "merchant-1", "physical", "presented"),
            MemberOfferSummary(id, "detail-house", "foreign", "digital", "presented"),
        )) {
            val (offers, _) = withSession(response("/offers/$id", fixture.toString()))
            assertThrows(MemberFailure.ScopeMismatch::class.java) { runBlocking { offers.detail(summary) } }
        }
    }

    @Test fun `detail refuses unknown missing foreign duplicate and unsafe values`() = runBlocking {
        fun changed(block: (MutableMap<String, kotlinx.serialization.json.JsonElement>) -> Unit): String {
            val map = fixture.toMutableMap(); block(map); return JsonObject(map).toString()
        }
        val id = fixture["id"]!!.jsonPrimitive.content
        val first = fixture["candidates"]!!.jsonArray[0].jsonObject
        val bad = listOf(
            changed { it["unexpected"] = kotlinx.serialization.json.JsonPrimitive(true) },
            changed { it.remove("price_band") },
            changed { it["household"] = kotlinx.serialization.json.JsonPrimitive("foreign") },
            changed { it["candidates"] = buildJsonArray { add(first); add(first) } },
            changed { map -> map["candidates"] = buildJsonArray { add(JsonObject(first.toMutableMap().also { it["quantity"] = kotlinx.serialization.json.JsonPrimitive(0) })); add(fixture["candidates"]!!.jsonArray[1]) } },
            changed { map -> map["expires_at"] = kotlinx.serialization.json.JsonPrimitive(9_007_199_254_740_992L) },
        )
        for (body in bad) {
            val (offers, _) = withSession(response("/offers/$id", body))
            assertThrows(MemberFailure::class.java) { runBlocking { offers.detail(id) } }
        }
    }

    @Test fun `collected_as is all rows or none and accepts only protocol verdicts`() {
        val candidates = fixture["candidates"]!!.jsonArray
        fun body(firstVerdict: String?, addSecond: Boolean): ByteArray {
            val root = fixture.toMutableMap()
            root["candidates"] = buildJsonArray {
                candidates.forEachIndexed { index, element ->
                    val row = element.jsonObject.toMutableMap()
                    if (index == 0 || addSecond) row["collected_as"] = firstVerdict?.let(::JsonPrimitive) ?: JsonNull
                    add(JsonObject(row))
                }
            }
            return JsonObject(root).toString().toByteArray()
        }
        val id = fixture["id"]!!.jsonPrimitive.content
        assertThrows(MemberFailure.Malformed::class.java) { MemberOfferCodec.detail(body("missing", false), id, "detail-house") }
        assertThrows(MemberFailure.Malformed::class.java) { MemberOfferCodec.detail(body("invalid", true), id, "detail-house") }
        assertTrue(MemberOfferCodec.detail(body("missing", true), id, "detail-house").collectedAsSupplied)
    }

    /**
     * Question 72, decided 2026-09-22. Absent (the captured fixture, from before this
     * field) and explicitly null both decode to no contact; present must be exactly
     * `kind` (one of three) and `value` (non-empty, at most 256 UTF-8 bytes), the same
     * limit the engine enforces before it will sign one.
     */
    @Test fun `disclosure contact is optional and validated`() {
        val id = fixture["id"]!!.jsonPrimitive.content
        fun withContact(contact: kotlinx.serialization.json.JsonElement?): ByteArray {
            val root = fixture.toMutableMap()
            root["disclosures"] = buildJsonArray {
                fixture["disclosures"]!!.jsonArray.forEachIndexed { index, element ->
                    val row = element.jsonObject.toMutableMap()
                    if (index == 0) { if (contact != null) row["contact"] = contact else row.remove("contact") }
                    add(JsonObject(row))
                }
            }
            return JsonObject(root).toString().toByteArray()
        }
        // The captured fixture predates the field: absent, and decodes to null.
        assertNull(MemberOfferCodec.detail(withContact(null), id, "detail-house").disclosures.single().contact)
        assertNull(MemberOfferCodec.detail(withContact(JsonNull), id, "detail-house").disclosures.single().contact)

        val ok = buildJsonObject { put("kind", "email"); put("value", "returns@maker-a.example") }
        assertEquals(MemberDisclosureContact("email", "returns@maker-a.example"), MemberOfferCodec.detail(withContact(ok), id, "detail-house").disclosures.single().contact)

        for (bad in listOf(
            buildJsonObject { put("kind", "email"); put("value", "x@example.com"); put("extra", "no") },
            buildJsonObject { put("kind", "post"); put("value", "x@example.com") },
            buildJsonObject { put("kind", "email"); put("value", "") },
            buildJsonObject { put("kind", "email") },
            JsonPrimitive("not an object"),
            buildJsonObject { put("kind", "email"); put("value", "a".repeat(251) + "@a.com") },
        )) {
            assertThrows(MemberFailure::class.java) { MemberOfferCodec.detail(withContact(bad), id, "detail-house") }
        }
    }

    @Test fun `locking private access fences a late offer response`() = runBlocking {
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); var calls = 0
        val list = """{"offers":[{"id":"offer-1","household":"detail-house","presenter":"merchant-1","binding":"digital","state":"presented"}]}"""
        val transport = object : MemberHttpTransport {
            override suspend fun send(request: MemberHttpRequest): MemberHttpResponse {
                calls++
                if (calls == 1) return response("/auth/session", sessionBody())
                entered.complete(Unit); release.await(); return response("/offers", list)
            }
        }
        val sessions = MemberSessionClient(environment, transport, OfferVault(StoredMemberSession(token, session))) { 1_800_000_000_000 }
        sessions.restore(session.household)
        val pending = async { runCatching { MemberOffers(sessions).list("merchant-1") }.exceptionOrNull() }
        entered.await(); sessions.lockLocalAccess(); release.complete(Unit)
        assertTrue(pending.await() is MemberFailure.Superseded)
    }

    // Vault `80` item 2: a presenter whose own read fails must not fail the union; it only
    // marks the union incomplete, the same as iOS's MemberProposals.refresh().
    @Test fun `listAll marks the union incomplete when one presenter cannot be read`() = runBlocking {
        val twoPresenters = MemberSessionInfo("session", "detail-house", listOf("merchant-1", "merchant-2"), 2_000_000_000_000)
        val twoPresenterBody = """{"id":"session","household":"detail-house","presenters":["merchant-1","merchant-2"],"expiresAt":2000000000000}"""
        val goodBody = """{"offers":[{"id":"offer-1","household":"detail-house","presenter":"merchant-2","binding":"digital","state":"presented"}]}"""
        val transport = OfferTransport(environment, ArrayDeque(listOf(
            response("/auth/session", twoPresenterBody),
            response("/offers", "not json"), // merchant-1, sorted first: fails to parse
            response("/offers", goodBody), // merchant-2: reads fine
        )))
        val sessions = MemberSessionClient(environment, transport, OfferVault(StoredMemberSession(token, twoPresenters))) { 1_800_000_000_000 }
        sessions.restore(twoPresenters.household)
        val result = MemberOffers(sessions).listAll(twoPresenters)
        assertTrue(result.incomplete)
        assertEquals(listOf("offer-1"), result.offers.map { it.id })
    }

    @Test fun `listAll propagates an expired session instead of swallowing it as a partial failure`() = runBlocking {
        val twoPresenters = MemberSessionInfo("session", "detail-house", listOf("merchant-1", "merchant-2"), 2_000_000_000_000)
        val twoPresenterBody = """{"id":"session","household":"detail-house","presenters":["merchant-1","merchant-2"],"expiresAt":2000000000000}"""
        val transport = OfferTransport(environment, ArrayDeque(listOf(
            response("/auth/session", twoPresenterBody),
            response("/offers", "{}", status = 401),
            response("/offers", """{"offers":[]}"""),
        )))
        val sessions = MemberSessionClient(environment, transport, OfferVault(StoredMemberSession(token, twoPresenters))) { 1_800_000_000_000 }
        sessions.restore(twoPresenters.household)
        assertThrows(MemberFailure.Http::class.java) { runBlocking { MemberOffers(sessions).listAll(twoPresenters) } }
        Unit
    }
}
