package dev.atarasy.prototype

import java.nio.charset.StandardCharsets
import kotlinx.coroutines.CancellationException
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

/**
 * What a list row can say without a second request per offer (`04b` §1b). Catalogue
 * revision 3: `name` and `variant` travel here too so a row's title never needs the
 * detail fetch. Every field but `product`/`merchant` is optional so a row from a host
 * that sends less still draws; the authoritative checks are the detail's.
 */
data class MemberOfferSummaryLine(
    val product: String,
    val merchant: String,
    val quantity: Long?,
    val unitPrice: Long?,
    val givenBy: String?,
    val valence: String?,
    val collectedAs: String?,
    val name: String?,
    val variant: String?,
)

data class MemberOfferSummary(
    val id: String,
    val household: String,
    val presenter: String,
    val binding: String,
    val state: String,
    val presentedAt: Long? = null,
    val expiresAt: Long? = null,
    val decidedAt: Long? = null,
    val candidates: List<MemberOfferSummaryLine>? = null,
) {
    /** The date a row is ordered by: when it arrived, and its expiry for a row never presented. */
    val arrivedAt: Long get() = presentedAt ?: expiresAt ?: 0L
}

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
    /** Catalogue revision 3. Absent where the catalogue row predates it. */
    val name: String? = null,
    val variant: String? = null,
)
data class MemberDisclosureItem(val label: String, val value: String)
/** Question 72, decided 2026-09-22. The merchant's own contact, shown beside its
 * return terms; null where it gave none. Rendered exactly as signed. */
data class MemberDisclosureContact(val kind: String, val value: String)
data class MemberDisclosure(
    val merchant: String,
    val product: String?,
    val version: String,
    val items: List<MemberDisclosureItem>,
    val signature: String,
    val contact: MemberDisclosureContact?,
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
    /** A row a host does not yet send these for still lists (`04b` §1b): the row falls back
     * to a generic title and no arrival ordering, rather than failing the whole list. */
    private val summaryOptionalKeys = setOf("presented_at", "expires_at", "decided_at", "candidates")
    private val summaryLineKeys = setOf("product", "merchant")
    private val summaryLineOptionalKeys = setOf("quantity", "unit_price", "given_by", "valence", "collected_as", "name", "variant")
    private val detailKeys = setOf(
        "id", "binding", "household", "presenter", "presenter_attested", "purpose", "price_band", "giver",
        "config_version", "presented_at", "expires_at", "state", "exploration_floor_met", "mandate", "candidates", "disclosures",
    )
    private val candidateKeys = setOf(
        "id", "product", "quantity", "unit_price", "merchant", "maker", "ships", "category", "predicted_conversion",
        "is_exploration", "given_by", "valence", "decided_at", "kept_as", "lineage",
    )
    /** Catalogue revision 3 rides alongside the always-present keys, independently of `collected_as`. */
    private val candidateOptionalKeys = setOf("collected_as", "name", "variant")
    private const val CATALOGUE_NAME_MAX = 120
    private const val CATALOGUE_VARIANT_MAX = 60
    private val disclosureKeys = setOf("merchant", "product", "version", "items", "signature")
    private val itemKeys = setOf("label", "value")
    private val contactKeys = setOf("kind", "value")
    private val contactKinds = setOf("email", "tel", "url")
    private val bindings = setOf("digital", "physical")
    private val states = setOf("drafted", "presented", "decided", "expired", "withdrawn", "settled")
    private val purposes = setOf("gift", "replenish", "trial", "ceremonial", "assortment")
    private val valences = setOf("offered", "kept", "returned", "consumed", "defaulted", "lost")
    private val collectedAsValues = setOf("returned", "consumed", "missing")

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
        requireKeys(value.keys, summaryKeys, summaryOptionalKeys)
        val result = MemberOfferSummary(
            id = value.string("id"), household = value.string("household"), presenter = value.string("presenter"),
            binding = value.string("binding"), state = value.string("state"),
            presentedAt = value.nullableSafeLong("presented_at", optionalKey = true),
            expiresAt = value.nullableSafeLong("expires_at", optionalKey = true),
            decidedAt = value.nullableSafeLong("decided_at", optionalKey = true),
            candidates = if (value.containsKey("candidates")) value.required("candidates").jsonArray.map { summaryLine(it.jsonObject) } else null,
        )
        require(result.id.isNotEmpty() && identifier(result.id))
        require(result.household == household && result.presenter == presenter) { "scope" }
        require(result.binding in bindings && result.state in states)
        return result
    }

    private fun summaryLine(value: JsonObject): MemberOfferSummaryLine {
        requireKeys(value.keys, summaryLineKeys, summaryLineOptionalKeys)
        val quantity = value.nullableSafeLong("quantity", optionalKey = true)
        val unitPrice = value.nullableSafeLong("unit_price", optionalKey = true)
        val valence = value.nullableString("valence", optionalKey = true)
        val collectedAs = value.nullableString("collected_as", optionalKey = true)
        val result = MemberOfferSummaryLine(
            product = value.string("product"), merchant = value.string("merchant"), quantity = quantity, unitPrice = unitPrice,
            givenBy = value.nullableString("given_by", optionalKey = true), valence = valence, collectedAs = collectedAs,
            name = value.optionalCatalogueText("name", CATALOGUE_NAME_MAX), variant = value.optionalCatalogueText("variant", CATALOGUE_VARIANT_MAX),
        )
        require(result.product.isNotEmpty() && result.merchant.isNotEmpty())
        require(quantity == null || quantity > 0)
        require(valence == null || valence in valences)
        require(collectedAs == null || collectedAs in collectedAsValues)
        return result
    }

    private fun candidate(value: JsonObject): MemberCandidate {
        requireKeys(value.keys, candidateKeys, candidateOptionalKeys)
        val result = MemberCandidate(
            id = value.string("id"), product = value.string("product"), quantity = value.safeLong("quantity"), unitPrice = value.safeLong("unit_price"),
            merchant = value.string("merchant"), maker = value.string("maker"), ships = value.string("ships"), category = value.nullableString("category"),
            predictedConversion = value.nullableDouble("predicted_conversion"), isExploration = value.boolean("is_exploration"),
            givenBy = value.nullableString("given_by"), valence = value.string("valence"), decidedAt = value.nullableSafeLong("decided_at"),
            keptAs = value.nullableString("kept_as"), lineage = value.nullableString("lineage"), collectedAs = value.nullableString("collected_as", optionalKey = true),
            name = value.optionalCatalogueText("name", CATALOGUE_NAME_MAX), variant = value.optionalCatalogueText("variant", CATALOGUE_VARIANT_MAX),
        )
        require(result.id.isNotEmpty() && result.product.isNotEmpty() && result.merchant.isNotEmpty() && result.maker.isNotEmpty() && result.ships.isNotEmpty())
        require(result.quantity > 0 && result.valence in valences)
        require(result.predictedConversion?.let { it.isFinite() && it in 0.0..1.0 } != false)
        require(result.keptAs == null || result.keptAs in setOf("self", "gift", "order"))
        require(result.givenBy == null || result.givenBy.isNotEmpty())
        require(result.collectedAs == null || result.collectedAs in collectedAsValues)
        return result
    }

    private fun disclosure(element: JsonElement): MemberDisclosure {
        val value = element.jsonObject; require(value.keys == disclosureKeys || value.keys == disclosureKeys + "contact")
        val items = value.required("items").jsonArray.map {
            val item = it.jsonObject; require(item.keys == itemKeys); MemberDisclosureItem(item.string("label"), item.string("value"))
        }
        return MemberDisclosure(value.string("merchant"), value.nullableString("product"), value.string("version"), items, value.string("signature"), contact(value))
    }
    /** Question 72. Absent or explicitly null is no contact; present must be exactly
     * `kind` (one of three) and `value` (non-empty, at most 256 UTF-8 bytes), the same
     * limit the engine enforces before it will sign one. */
    private fun contact(value: JsonObject): MemberDisclosureContact? {
        if (!value.containsKey("contact")) return null
        val raw = value.required("contact")
        if (raw === JsonNull) return null
        val c = raw.jsonObject; require(c.keys == contactKeys)
        val kind = c.string("kind"); require(kind in contactKinds)
        val contactValue = c.string("value"); require(contactValue.isNotEmpty() && contactValue.toByteArray(StandardCharsets.UTF_8).size <= 256)
        return MemberDisclosureContact(kind, contactValue)
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
    /**
     * Catalogue revision 3's `name` and `variant`. Absent is legitimate (a pre-revision-3
     * catalogue row); present must be a nonempty string within the bound in Unicode code
     * points, never explicit null. An unknown key elsewhere is still refused by `requireKeys`.
     */
    private fun JsonObject.optionalCatalogueText(key: String, maxCodePoints: Int): String? {
        if (!containsKey(key)) return null
        val text = required(key).jsonPrimitive.let { require(it.isString); it.content }
        require(text.isNotEmpty() && text.codePointCount(0, text.length) <= maxCodePoints)
        return text
    }
    private fun requireKeys(actual: Set<String>, required: Set<String>, optional: Set<String>) {
        require(required.all { it in actual } && (actual - required).all { it in optional })
    }
    private fun identifier(value: String) = value.isNotEmpty() && value.all { it.isLetterOrDigit() || it == '_' || it == '-' }
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: IllegalArgumentException) {
        if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed
    } catch (_: Exception) { throw MemberFailure.Malformed }
}

/**
 * The union of every presenter's rows, plus whether every presenter answered. `incomplete`
 * is true when at least one presenter's list could not be read, so a row-less section can be
 * told apart from a section nobody could check (vault `80` §6.2 I, "may be incomplete").
 */
data class MemberOfferListResult(val offers: List<MemberOfferSummary>, val incomplete: Boolean)

class MemberOffers(private val sessions: MemberSessionClient) {
    suspend fun list(presenter: String): List<MemberOfferSummary> {
        if (presenter.isEmpty()) throw MemberFailure.ScopeMismatch
        return listForSession(sessions.activeInfo(), presenter)
    }

    /**
     * A presenter whose own read fails (a malformed body, a foreign row, a transport error)
     * is dropped from the union rather than failing the whole list, the same as iOS's
     * `MemberProposals.refresh()`. Only a failure that ends the private session itself
     * (expired, superseded, or a 401) propagates; every other per-presenter failure just
     * marks the union `incomplete`.
     */
    suspend fun listAll(session: MemberSessionInfo): MemberOfferListResult = coroutineScope {
        if (sessions.activeInfo() != session) throw MemberFailure.ScopeMismatch
        val permits = Semaphore(4)
        val outcomes = session.presenters.sorted().map { presenter ->
            async {
                permits.withPermit {
                    try {
                        listForSession(session, presenter)
                    } catch (failure: CancellationException) {
                        throw failure
                    } catch (failure: MemberFailure.Expired) {
                        throw failure
                    } catch (failure: MemberFailure.Superseded) {
                        throw failure
                    } catch (failure: MemberFailure.Http) {
                        if (failure.status == 401) throw failure
                        null
                    } catch (_: Exception) {
                        null
                    }
                }
            }
        }.awaitAll()
        MemberOfferListResult(outcomes.filterNotNull().flatten(), incomplete = outcomes.any { it == null })
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
