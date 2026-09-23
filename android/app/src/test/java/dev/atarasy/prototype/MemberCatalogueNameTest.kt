package dev.atarasy.prototype

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Catalogue revision 3's `name` and `variant`, ported to the candidate on the offer
 * detail, the approval, the statement line and the settlement line. Absent is
 * legitimate (a pre-revision-3 catalogue row); present must be nonempty text bounded
 * in Unicode code points; an unknown key is still refused.
 */
class MemberCatalogueNameTest {
    private val json = Json { ignoreUnknownKeys = false }
    private val root by lazy { json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-review-responses.json")).readText()).jsonObject }
    private fun value(name: String): JsonObject = root["cases"]!!.jsonArray.first { it.jsonObject["name"]!!.jsonPrimitive.content == name }.jsonObject["value"]!!.jsonObject
    private fun changed(name: String, block: (MutableMap<String, JsonElement>) -> Unit): ByteArray =
        value(name).toMutableMap().also(block).let(::JsonObject).toString().toByteArray()

    /** Sets or removes a field on the row whose `idKey` equals `id`, inside the `listKey` array. */
    private fun withRowField(name: String, listKey: String, idKey: String, id: String, field: String, fieldValue: JsonElement?): ByteArray = changed(name) { map ->
        val rows = map.getValue(listKey).jsonArray.map { element ->
            val row = element.jsonObject
            if (row[idKey]?.jsonPrimitive?.content == id) {
                val mutable = row.toMutableMap()
                if (fieldValue != null) mutable[field] = fieldValue else mutable.remove(field)
                JsonObject(mutable) as JsonElement
            } else element
        }
        map[listKey] = JsonArray(rows)
    }

    private fun detailBytes(name: String) = value(name).toString().toByteArray()

    // ---- detail candidate ----

    @Test fun `detail accepts a name and variant and refuses an empty one`() {
        val id = "1795cde3-6d08-48a1-8082-2b39e1b41e11"
        val named = withRowField("digital-detail", "candidates", "id", id, "name", JsonPrimitive("Sencha"))
        val detail = MemberOfferCodec.detail(named, value("digital-detail")["id"]!!.jsonPrimitive.content, "detail-house")
        assertEquals("Sencha", detail.candidates.first { it.id == id }.name)
        assertNull(detail.candidates.first { it.id != id }.name)

        assertThrows(MemberFailure::class.java) {
            MemberOfferCodec.detail(
                withRowField("digital-detail", "candidates", "id", id, "name", JsonPrimitive("")),
                value("digital-detail")["id"]!!.jsonPrimitive.content, "detail-house",
            )
        }
        assertThrows(MemberFailure::class.java) {
            MemberOfferCodec.detail(
                withRowField("digital-detail", "candidates", "id", id, "name", JsonPrimitive("x".repeat(121))),
                value("digital-detail")["id"]!!.jsonPrimitive.content, "detail-house",
            )
        }
        // 120 code points is the boundary, not the refusal.
        val boundary = MemberOfferCodec.detail(
            withRowField("digital-detail", "candidates", "id", id, "name", JsonPrimitive("x".repeat(120))),
            value("digital-detail")["id"]!!.jsonPrimitive.content, "detail-house",
        )
        assertEquals(120, boundary.candidates.first { it.id == id }.name!!.length)
    }

    @Test fun `detail refuses a variant longer than 60 code points and an explicit null`() {
        val id = "1795cde3-6d08-48a1-8082-2b39e1b41e11"
        assertThrows(MemberFailure::class.java) {
            MemberOfferCodec.detail(
                withRowField("digital-detail", "candidates", "id", id, "variant", JsonPrimitive("x".repeat(61))),
                value("digital-detail")["id"]!!.jsonPrimitive.content, "detail-house",
            )
        }
        assertThrows(MemberFailure::class.java) {
            MemberOfferCodec.detail(
                withRowField("digital-detail", "candidates", "id", id, "name", kotlinx.serialization.json.JsonNull),
                value("digital-detail")["id"]!!.jsonPrimitive.content, "detail-house",
            )
        }
        assertThrows(MemberFailure::class.java) {
            MemberOfferCodec.detail(
                withRowField("digital-detail", "candidates", "id", id, "colour", JsonPrimitive("red")),
                value("digital-detail")["id"]!!.jsonPrimitive.content, "detail-house",
            )
        }
    }

    // ---- approval and statement candidates must match the detail's ----

    @Test fun `approval candidate name and variant must match the detail`() {
        val id = "1795cde3-6d08-48a1-8082-2b39e1b41e11"
        val detailBytes = withRowField("digital-detail", "candidates", "id", id, "name", JsonPrimitive("Sencha"))
        val detail = MemberOfferCodec.detail(detailBytes, value("digital-detail")["id"]!!.jsonPrimitive.content, "detail-house")

        val matching = withRowField("digital-known-carriage", "candidates", "id", id, "name", JsonPrimitive("Sencha"))
        val approval = MemberReviewCodec.approval(matching, detail)
        assertEquals("Sencha", approval.candidates.first { it.id == id }.name)

        val mismatched = withRowField("digital-known-carriage", "candidates", "id", id, "name", JsonPrimitive("Gyokuro"))
        assertThrows(MemberFailure::class.java) { MemberReviewCodec.approval(mismatched, detail) }

        val missingOnApproval = value("digital-known-carriage").toString().toByteArray()
        assertThrows(MemberFailure::class.java) { MemberReviewCodec.approval(missingOnApproval, detail) }
    }

    @Test fun `statement line name and variant must match the detail`() {
        val id = "41f9649a-b3ea-4934-83b3-444fc6bd30e9"
        val detailBytes = withRowField("physical-detail", "candidates", "id", id, "name", JsonPrimitive("Colombian"))
        val detail = MemberOfferCodec.detail(detailBytes, value("physical-detail")["id"]!!.jsonPrimitive.content, "detail-house")

        val matching = withRowField("physical-known-carriage", "lines", "candidate", id, "name", JsonPrimitive("Colombian"))
        val statement = MemberReviewCodec.statement(matching, detail)
        assertEquals("Colombian", statement.lines.first { it.candidate == id }.name)

        val mismatched = withRowField("physical-known-carriage", "lines", "candidate", id, "name", JsonPrimitive("Ethiopian"))
        assertThrows(MemberFailure::class.java) { MemberReviewCodec.statement(mismatched, detail) }
    }

    // ---- settlement line: standalone, no detail to match against ----

    @Test fun `settlement line name must be text and rejects an unknown key`() {
        val fixture = json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-operation-runtime.json")).readText())
            .jsonObject["committed"]!!.jsonObject["receipt"]!!.jsonObject
        val id = fixture["offer"]!!.jsonPrimitive.content

        val withName = JsonObject(fixture.toMutableMap().also { root ->
            root["lines"] = JsonArray(root.getValue("lines").jsonArray.mapIndexed { i, element ->
                if (i == 0) JsonObject(element.jsonObject.toMutableMap().also { it["name"] = JsonPrimitive("Sencha") }) as JsonElement else element
            })
        })
        val decoded = MemberSettlementCodec.decode(withName.toString().toByteArray(), id)
        assertEquals("Sencha", decoded.lines[0].name)

        // Absent stays legitimate.
        MemberSettlementCodec.decode(fixture.toString().toByteArray(), id)

        val withNumberName = JsonObject(fixture.toMutableMap().also { root ->
            root["lines"] = JsonArray(root.getValue("lines").jsonArray.mapIndexed { i, element ->
                if (i == 0) JsonObject(element.jsonObject.toMutableMap().also { it["name"] = JsonPrimitive(3) }) as JsonElement else element
            })
        })
        assertThrows(MemberFailure::class.java) { MemberSettlementCodec.decode(withNumberName.toString().toByteArray(), id) }

        val withUnknownKey = JsonObject(fixture.toMutableMap().also { root ->
            root["lines"] = JsonArray(root.getValue("lines").jsonArray.mapIndexed { i, element ->
                if (i == 0) JsonObject(element.jsonObject.toMutableMap().also { it["colour"] = JsonPrimitive("red") }) as JsonElement else element
            })
        })
        assertThrows(MemberFailure::class.java) { MemberSettlementCodec.decode(withUnknownKey.toString().toByteArray(), id) }
    }

    // ---- list summary line: fully optional, tolerant of absence ----

    @Test fun `summary line reads name and variant and tolerates their absence`() {
        val body = """{"offers":[{"id":"offer-1","household":"h","presenter":"p","binding":"physical","state":"presented","presented_at":10,"expires_at":20,"candidates":[{"product":"tea","merchant":"Shop","quantity":2,"unit_price":300,"given_by":null,"valence":"consumed","collected_as":"consumed","name":"Sencha","variant":"100g"}]}]}"""
        val summaries = MemberOfferCodec.summaries(body.toByteArray(), "h", "p")
        assertEquals("Sencha", summaries.single().candidates!!.single().name)
        assertEquals("100g", summaries.single().candidates!!.single().variant)
        assertEquals(10L, summaries.single().arrivedAt)

        val bare = """{"offers":[{"id":"offer-1","household":"h","presenter":"p","binding":"digital","state":"presented"}]}"""
        val bareSummaries = MemberOfferCodec.summaries(bare.toByteArray(), "h", "p")
        assertNull(bareSummaries.single().candidates)
        assertEquals(0L, bareSummaries.single().arrivedAt)
    }
}
