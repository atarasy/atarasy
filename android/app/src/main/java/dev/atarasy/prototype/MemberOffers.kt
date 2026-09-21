package dev.atarasy.prototype

import java.nio.charset.StandardCharsets
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

data class MemberOfferSummary(
    val id: String,
    val household: String,
    val presenter: String,
    val binding: String,
    val state: String,
)

data class MemberPriceBand(val min: Long, val max: Long)
data class MemberCandidate(
    val id: String,
    val product: String,
    val quantity: Long,
    val unitPrice: Long,
    val merchant: String,
    val maker: String,
    val ships: String,
    val category: String?,
    val predictedConversion: Double?,
    val isExploration: Boolean,
    val givenBy: String?,
    val valence: String,
    val decidedAt: Long?,
    val keptAs: String?,
    val lineage: String?,
    val collectedAs: String?,
)
data class MemberDisclosureItem(val label: String, val value: String)
data class MemberDisclosure(
    val merchant: String,
    val product: String?,
    val version: String,
    val items: List<MemberDisclosureItem>,
    val signature: String,
)
data class MemberOfferDetail(
    val id: String,
    val binding: String,
    val household: String,
    val presenter: String,
    val presenterAttested: Boolean,
    val purpose: String,
    val priceBand: MemberPriceBand?,
    val giver: String?,
    val configVersion: String,
    val presentedAt: Long?,
    val expiresAt: Long,
    val state: String,
    val decidedAt: Long?,
    val explorationFloorMet: Boolean,
    val mandate: String,
    val candidates: List<MemberCandidate>,
    val disclosures: List<MemberDisclosure>,
    val collectedAsSupplied: Boolean,
)

object MemberOfferCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val summaryKeys = setOf("id", "household", "presenter", "binding", "state")
    private val detailKeys = setOf(
        "id", "binding", "household", "presenter", "presenter_attested", "purpose", "price_band", "giver",
        "config_version", "presented_at", "expires_at", "state", "exploration_floor_met", "mandate", "candidates", "disclosures",
    )
    private val candidateKeys = setOf(
        "id", "product", "quantity", "unit_price", "merchant", "maker", "ships", "category", "predicted_conversion",
        "is_exploration", "given_by", "valence", "decided_at", "kept_as", "lineage",
    )
    private val disclosureKeys = setOf("merchant", "product", "version", "items", "signature")
    private val itemKeys = setOf("label", "value")
    private val bindings = setOf("digital", "physical")
    private val states = setOf("drafted", "presented", "decided", "expired", "withdrawn", "settled")
    private val purposes = setOf("gift", "replenish", "trial", "ceremonial", "assortment")
    private val valences = setOf("offered", "kept", "returned", "consumed", "defaulted", "lost")

    fun summaries(bytes: ByteArray, household: String, presenter: String): List<MemberOfferSummary> = malformed {
        val root = objectOf(bytes)
        require(root.keys == setOf("offers"))
        root.required("offers").jsonArray.map { summary(it.jsonObject, household, presenter) }.also { rows ->
            require(rows.map { it.id }.distinct().size == rows.size)
        }
    }

    fun detail(bytes: ByteArray, expectedId: String, household: String, presenter: String? = null): MemberOfferDetail = malformed {
        require(identifier(expectedId))
        val value = objectOf(bytes)
        require(value.keys == detailKeys || value.keys == detailKeys + "decided_at")
        val candidatesJson = value.required("candidates").jsonArray.map { it.jsonObject }
        val supplied = candidatesJson.map { it.containsKey("collected_as") }.distinct()
        require(supplied.size <= 1)
        val candidates = candidatesJson.map(::candidate)
        require(candidates.map { it.id }.distinct().size == candidates.size)
        val disclosures = value.required("disclosures").jsonArray.map(::disclosure)
        val band = value.optionalObject("price_band")?.let {
            require(it.keys == setOf("min", "max")); MemberPriceBand(it.safeLong("min"), it.safeLong("max")).also { b -> require(b.min <= b.max) }
        }
        val result = MemberOfferDetail(
            id = value.string("id"), binding = value.string("binding"), household = value.string("household"), presenter = value.string("presenter"),
            presenterAttested = value.boolean("presenter_attested"), purpose = value.string("purpose"), priceBand = band,
            giver = value.nullableString("giver"), configVersion = value.string("config_version"), presentedAt = value.nullableSafeLong("presented_at"),
            expiresAt = value.safeLong("expires_at"), state = value.string("state"), decidedAt = value.nullableSafeLong("decided_at", optionalKey = true),
            explorationFloorMet = value.boolean("exploration_floor_met"), mandate = value.string("mandate"), candidates = candidates,
            disclosures = disclosures, collectedAsSupplied = supplied.singleOrNull() == true,
        )
        require(result.id == expectedId && result.household == household && (presenter == null || result.presenter == presenter)) { "scope" }
        require(result.binding in bindings && result.state in states && result.purpose in purposes)
        require(result.presenter.isNotEmpty() && result.household.isNotEmpty() && result.configVersion.isNotEmpty() && result.mandate.isNotEmpty())
        require((result.purpose == "ceremonial") == (band != null && !result.giver.isNullOrEmpty()))
        require(result.purpose == "ceremonial" || (band == null && result.giver == null))
        require(disclosures.all { d -> d.merchant.isNotEmpty() && d.version.isNotEmpty() && d.signature.isNotEmpty() && candidates.any { c -> c.merchant == d.merchant && (d.product == null || c.product == d.product) } })
        result
    }

    private fun summary(value: JsonObject, household: String, presenter: String): MemberOfferSummary {
        require(value.keys == summaryKeys)
        val result = MemberOfferSummary(value.string("id"), value.string("household"), value.string("presenter"), value.string("binding"), value.string("state"))
        require(result.id.isNotEmpty() && identifier(result.id))
        require(result.household == household && result.presenter == presenter) { "scope" }
        require(result.binding in bindings && result.state in states)
        return result
    }

    private fun candidate(value: JsonObject): MemberCandidate {
        require(value.keys == candidateKeys || value.keys == candidateKeys + "collected_as")
        val result = MemberCandidate(
            id = value.string("id"), product = value.string("product"), quantity = value.safeLong("quantity"), unitPrice = value.safeLong("unit_price"),
            merchant = value.string("merchant"), maker = value.string("maker"), ships = value.string("ships"), category = value.nullableString("category"),
            predictedConversion = value.nullableDouble("predicted_conversion"), isExploration = value.boolean("is_exploration"),
            givenBy = value.nullableString("given_by"), valence = value.string("valence"), decidedAt = value.nullableSafeLong("decided_at"),
            keptAs = value.nullableString("kept_as"), lineage = value.nullableString("lineage"), collectedAs = value.nullableString("collected_as", optionalKey = true),
        )
        require(result.id.isNotEmpty() && result.product.isNotEmpty() && result.merchant.isNotEmpty() && result.maker.isNotEmpty() && result.ships.isNotEmpty())
        require(result.quantity > 0 && result.valence in valences)
        require(result.predictedConversion?.let { it.isFinite() && it in 0.0..1.0 } != false)
        require(result.keptAs == null || result.keptAs in setOf("self", "gift", "order"))
        require(result.givenBy == null || result.givenBy.isNotEmpty())
        require(result.collectedAs == null || result.collectedAs in setOf("returned", "consumed", "missing"))
        return result
    }

    private fun disclosure(element: JsonElement): MemberDisclosure {
        val value = element.jsonObject; require(value.keys == disclosureKeys)
        val items = value.required("items").jsonArray.map {
            val item = it.jsonObject; require(item.keys == itemKeys); MemberDisclosureItem(item.string("label"), item.string("value"))
        }
        return MemberDisclosure(value.string("merchant"), value.nullableString("product"), value.string("version"), items, value.string("signature"))
    }

    private fun objectOf(bytes: ByteArray): JsonObject = json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject
    private fun JsonObject.required(key: String): JsonElement = getValue(key)
    private fun JsonObject.string(key: String): String = required(key).jsonPrimitive.let { require(it.isString); it.content }
    private fun JsonObject.nullableString(key: String, optionalKey: Boolean = false): String? {
        if (optionalKey && !containsKey(key)) return null
        val item = required(key); if (item === JsonNull) return null
        return item.jsonPrimitive.let { require(it.isString); it.content }
    }
    private fun JsonObject.boolean(key: String): Boolean = required(key).jsonPrimitive.let { require(!it.isString); it.boolean }
    private fun JsonObject.safeLong(key: String): Long = required(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun JsonObject.nullableSafeLong(key: String, optionalKey: Boolean = false): Long? {
        if (optionalKey && !containsKey(key)) return null
        return required(key).takeUnless { it === JsonNull }?.let { item -> item.jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) } }
    }
    private fun JsonObject.nullableDouble(key: String): Double? = required(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(!it.isString); it.double }
    private fun JsonObject.optionalObject(key: String): JsonObject? = required(key).takeUnless { it === JsonNull }?.jsonObject
    private fun identifier(value: String) = value.isNotEmpty() && value.all { it.isLetterOrDigit() || it == '_' || it == '-' }
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: IllegalArgumentException) {
        if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed
    } catch (_: Exception) { throw MemberFailure.Malformed }
}

class MemberOffers(private val sessions: MemberSessionClient) {
    suspend fun list(presenter: String): List<MemberOfferSummary> {
        if (presenter.isEmpty()) throw MemberFailure.ScopeMismatch
        return listForSession(sessions.activeInfo(), presenter)
    }

    suspend fun listAll(session: MemberSessionInfo): List<MemberOfferSummary> = coroutineScope {
        if (sessions.activeInfo() != session) throw MemberFailure.ScopeMismatch
        val permits = Semaphore(4)
        session.presenters.sorted().map { presenter -> async { permits.withPermit { listForSession(session, presenter) } } }.awaitAll().flatten()
    }

    suspend fun detail(id: String): MemberOfferDetail {
        return detail(id, null)
    }

    suspend fun detail(expected: MemberOfferSummary): MemberOfferDetail {
        return detail(expected.id, expected)
    }

    private suspend fun detail(id: String, expected: MemberOfferSummary?): MemberOfferDetail {
        if (!id.all { it.isLetterOrDigit() || it == '_' || it == '-' } || id.isEmpty()) throw MemberFailure.Malformed
        val (reply, session) = sessions.readWithSession("/offers/$id")
        response(reply)
        if (expected != null && (expected.household != session.household || expected.presenter !in session.presenters)) throw MemberFailure.ScopeMismatch
        val value = MemberOfferCodec.detail(reply.body, id, session.household, expected?.presenter)
        if (value.presenter !in session.presenters) throw MemberFailure.ScopeMismatch
        if (expected != null && value.binding != expected.binding) throw MemberFailure.ScopeMismatch
        return value
    }

    private suspend fun listForSession(expected: MemberSessionInfo, presenter: String): List<MemberOfferSummary> {
        if (presenter !in expected.presenters) throw MemberFailure.ScopeMismatch
        val (reply, current) = sessions.readWithSession("/offers", listOf("household" to expected.household, "presenter" to presenter))
        if (current != expected || presenter !in current.presenters) throw MemberFailure.Superseded
        response(reply)
        return MemberOfferCodec.summaries(reply.body, current.household, presenter)
    }

    private fun response(reply: MemberHttpResponse) {
        if (reply.status != 200) throw MemberFailure.Http(reply.status)
        if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed
    }
}
