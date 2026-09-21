package dev.atarasy.prototype

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CanonicalTest {
    private val vectors by lazy {
        val text = requireNotNull(javaClass.getResource("/canonical-vectors.json")).readText()
        Json.parseToJsonElement(text).jsonArray
    }

    @Test fun `all independent canonical vectors match bytes digest and challenge`() {
        assertEquals(11, vectors.size)
        vectors.forEach { raw ->
            val value = raw.jsonObject
            val canonical = when (value.text("kind")) {
                "decision" -> Canonical.decisions(value.text("offer"), value.getValue("decisions").jsonArray.map { row ->
                    val item = row.jsonObject
                    Decision(item.text("candidate"), item.text("valence"), item.optionalText("kept_as"), item.optionalText("lineage"))
                })
                "statement" -> Canonical.statement(value.text("offer"), value.getValue("carriage").jsonPrimitive.long, value.getValue("lines").jsonArray.map { row ->
                    val item = row.jsonObject
                    StatementLine(item.text("candidate"), item.text("valence"), item.getValue("amount").jsonPrimitive.long, item.getValue("disputed").jsonPrimitive.boolean)
                })
                "mandate" -> {
                    val item = value.getValue("mandate").jsonObject
                    Canonical.mandate(Mandate(
                        item.text("id"), item.text("household"), item.getValue("ceiling_out_of_network").jsonPrimitive.long,
                        item.optionalLong("ceiling_daily"), item.optionalLong("cooling_seconds"),
                        item.getValue("co_signers").jsonArray.map { it.jsonPrimitive.content },
                        item.getValue("lapses_at").jsonPrimitive.long, item.getValue("version").jsonPrimitive.long,
                    ), value.text("host"))
                }
                else -> error("Unknown vector kind")
            }
            assertEquals(value.text("id"), value.text("canonical"), canonical)
            assertEquals(value.text("id"), value.text("sha256"), Canonical.digest(canonical))
            assertEquals(value.text("id"), value.text("challenge"), Canonical.challenge(canonical))
        }
    }

    @Test fun `Java UTF-16 order is the protocol order and normalisation remains distinct`() {
        val text = Canonical.decisions("unicode", listOf(
            Decision("\uE000", "returned"), Decision("😀", "kept", "self"), Decision("é", "returned"),
        ))
        assertEquals(listOf("é:returned::", "😀:kept:self:", "\uE000:returned::"), text.lines().drop(1))
        assertNotEquals(
            Canonical.decisions("o", listOf(Decision("é", "returned"))),
            Canonical.decisions("o", listOf(Decision("e\u0301", "returned"))),
        )
    }

    @Test fun `ambiguous identifiers unsafe amounts and exact duplicate identities are refused`() {
        assertThrows(IllegalArgumentException::class.java) { Canonical.decisions("o", listOf(Decision("a:b", "kept"))) }
        assertThrows(IllegalArgumentException::class.java) { Canonical.decisions("o", listOf(Decision("a", "kept"), Decision("a", "returned"))) }
        assertThrows(IllegalArgumentException::class.java) { Canonical.statement("o", Canonical.MAXIMUM_INTEGER + 1, emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { Canonical.statement("o", 0, listOf(StatementLine("a", "lost", 1, false))) }
        assertThrows(IllegalArgumentException::class.java) { Canonical.statement("o", 0, listOf(StatementLine("a", "kept", 0, true))) }
    }

    @Test fun `mandate signer escaping uses exact UTF-8 percent encoding`() {
        val mandate = Mandate("m", "h", 0, null, null, listOf("!*'()~", "a b", "é"), 1, 1)
        assertEquals("!*'()~,a%20b,%C3%A9", Canonical.mandate(mandate, "host").lines()[7])
    }

    private fun JsonObject.text(key: String) = getValue(key).jsonPrimitive.content
    private fun JsonObject.optionalText(key: String) = this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
    private fun JsonObject.optionalLong(key: String) = this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.long
}
