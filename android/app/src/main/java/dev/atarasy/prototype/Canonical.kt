package dev.atarasy.prototype

import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Base64

data class Decision(val candidate: String, val valence: String, val keptAs: String? = null, val lineage: String? = null)
data class StatementLine(val candidate: String, val valence: String, val amount: Long, val disputed: Boolean)
data class Mandate(
    val id: String,
    val household: String,
    val ceilingOutOfNetwork: Long,
    val ceilingDaily: Long?,
    val coolingSeconds: Long?,
    val coSigners: List<String>,
    val lapsesAt: Long,
    val version: Long,
)

object Canonical {
    const val MAXIMUM_INTEGER = 9_007_199_254_740_991L
    private val utf16Order = Comparator<String> { left, right -> left.compareTo(right) }

    private fun integer(value: Long) = require(value in 0..MAXIMUM_INTEGER)
    private fun identifier(value: String) = require(value.isNotEmpty() && '\n' !in value && '\r' !in value && ':' !in value)
    private fun line(value: String) = require(value.isNotEmpty() && '\n' !in value && '\r' !in value)
    private fun unique(values: List<String>) = require(values.distinct().size == values.size)
    private fun encoded(value: String): String = buildString {
        val allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".map { it.code }.toSet()
        value.toByteArray(StandardCharsets.UTF_8).forEach { byte ->
            val unsigned = byte.toInt() and 0xff
            if (unsigned in allowed) append(unsigned.toChar()) else append("%%%02X".format(unsigned))
        }
    }

    fun decisions(offer: String, lines: List<Decision>): String {
        identifier(offer)
        unique(lines.map { it.candidate })
        lines.forEach {
            identifier(it.candidate)
            require(it.valence == "kept" || it.valence == "returned")
            require(it.keptAs == null || it.keptAs in setOf("self", "gift", "order"))
            it.lineage?.let(::identifier)
        }
        return (listOf(offer) + lines.sortedWith(compareBy(utf16Order) { it.candidate })
            .map { "${it.candidate}:${it.valence}:${it.keptAs.orEmpty()}:${it.lineage.orEmpty()}" }).joinToString("\n")
    }

    fun statement(offer: String, carriage: Long?, lines: List<StatementLine>): String {
        identifier(offer)
        requireNotNull(carriage).also(::integer)
        unique(lines.map { it.candidate })
        lines.forEach {
            identifier(it.candidate); integer(it.amount)
            require(it.valence in setOf("kept", "defaulted", "consumed", "lost"))
            require(it.valence != "lost" || it.amount == 0L)
            require(!it.disputed || it.valence == "consumed" || it.valence == "lost")
        }
        return (listOf("valence.statement.1", offer, carriage.toString()) +
            lines.sortedWith(compareBy(utf16Order) { it.candidate })
                .map { "${it.candidate}:${it.valence}:${it.amount}:${if (it.disputed) "disputed" else ""}" }).joinToString("\n")
    }

    fun validateMandate(value: Mandate) {
        line(value.id); line(value.household)
        listOfNotNull(value.ceilingOutOfNetwork, value.ceilingDaily, value.coolingSeconds, value.lapsesAt, value.version).forEach(::integer)
        require(value.version >= 1)
    }

    fun mandate(value: Mandate, host: String): String {
        validateMandate(value); line(host)
        return listOf(
            "valence.mandate.2", host, value.id, value.household, value.ceilingOutOfNetwork.toString(),
            value.ceilingDaily?.toString().orEmpty(), value.coolingSeconds?.toString().orEmpty(),
            value.coSigners.sortedWith(utf16Order).joinToString(",", transform = ::encoded),
            value.lapsesAt.toString(), value.version.toString(),
        ).joinToString("\n")
    }

    private fun digestBytes(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(StandardCharsets.UTF_8))
    fun digest(text: String): String = digestBytes(text).joinToString("") { "%02x".format(it) }
    fun challenge(text: String): String = Base64.getUrlEncoder().withoutPadding().encodeToString(digestBytes(text))
}
