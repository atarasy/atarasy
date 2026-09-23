package dev.atarasy.prototype

import java.nio.charset.StandardCharsets
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

sealed interface MemberReview {
    data class Approval(val value: MemberApproval) : MemberReview
    data class Statement(val value: MemberStatement) : MemberReview
    /**
     * §6.6, question 70. `corrections` is whatever the merchant has appended
     * beside this settlement, or null where the read found nothing to show
     * (a 404, a malformed body, or a scope mismatch): never a reason to fail
     * the settlement itself, which is why it is not part of decoding `value`.
     * SPEC §6.6a: `disclosures` is the offer's own, carried alongside so a
     * correction_return can be shown beside the merchant's signed contact or
     * its return terms without a second fetch.
     */
    data class Settlement(val value: ProtocolSettlement, val corrections: MemberCorrections? = null, val disclosures: List<MemberDisclosure> = emptyList()) : MemberReview
}
data class MemberDisclosureReference(val merchant: String, val product: String?)
data class MemberMandateTerms(val kind: String, val scope: String, val lapsesAt: Long?)
data class MemberApprovalCandidate(
    val id: String, val product: String, val merchant: String, val maker: String, val ships: String, val givenBy: String?,
    val quantity: Long, val unitPrice: Long, val isExploration: Boolean, val valence: String, val alternatives: List<String>,
    val argumentAgainst: String, val disclosure: MemberDisclosureReference,
    /** Catalogue revision 3. Matched against the offer's own candidate in `approval()`. */
    val name: String? = null, val variant: String? = null,
)
data class MemberExcluded(val product: String, val reason: String)
data class MemberApproval(
    val offer: String, val presenter: String, val expiresAt: Long, val carriage: Long?, val priceBand: MemberPriceBand?,
    val disclosures: List<MemberDisclosure>, val reminded: Boolean, val mandate: MemberMandateTerms,
    val candidates: List<MemberApprovalCandidate>, val excluded: List<MemberExcluded>,
)
data class MemberStatementLine(
    val candidate: String, val product: String, val merchant: String, val maker: String, val ships: String, val givenBy: String?,
    val valence: String, val quantity: Long, val unitPrice: Long, val amount: Long, val note: String?, val disclosure: MemberDisclosureReference,
    /** Catalogue revision 3. Matched against the eligible or lost candidate this line settles. */
    val name: String? = null, val variant: String? = null,
)
data class MemberStatement(
    val offer: String, val household: String, val expiresAt: Long, val lines: List<MemberStatementLine>,
    val disclosures: List<MemberDisclosure>, val carriage: Long?, val challenge: String,
)
data class ProtocolSettlementLine(
    val candidate: String, val product: String, val merchant: String, val maker: String, val ships: String,
    val valence: String, val amount: Long, val disputed: Boolean,
    /** Catalogue revision 3. Not matched against anything else here: the settlement decode takes no detail. */
    val name: String? = null, val variant: String? = null,
)
data class ProtocolSettlement(
    val offer: String, val settledAt: Long, val keptAmount: Long, val consumedAmount: Long, val lostAmount: Long,
    val charged: Long, val disputedAmount: Long, val lines: List<ProtocolSettlementLine>, val payer: String,
    val signedBy: String, val signedAs: String, val receipt: String, val confirmation: String?,
)

/**
 * §6.6, question 70. The household's receipt of what a merchant has appended
 * beside a settlement it signed: the original as it was signed, each
 * correction in the order it arrived, and what remains. The settlement
 * itself is never rewritten.
 */
data class MemberCorrectionOriginal(val charged: Long, val carriage: Long?)
data class MemberCorrection(
    val id: String, val offer: String, val merchant: String, val amount: Long, val kind: String,
    val note: String, val correctedAt: Long, val signature: String,
)
/**
 * SPEC §6.6a. A merchant's signed record that a `refund` correction it already
 * posted did not reach the household (the issuer returned it), or that it
 * later repaid the household another way. Neither moves money through this
 * platform; the shop and the household settle directly, and this is a record
 * of that, not a channel for it.
 */
data class MemberCorrectionReturn(
    val correction: String, val offer: String, val merchant: String, val state: String,
    val note: String, val at: Long, val signature: String,
)
data class MemberCorrections(
    val offer: String, val original: MemberCorrectionOriginal, val corrections: List<MemberCorrection>, val net: Long,
    /** Present only when at least one return is held for this offer. */
    val returns: List<MemberCorrectionReturn>? = null,
    /** Present only alongside `returns`: the sum owed for refunds returned and not yet repaid. */
    val owed: Long? = null,
)

object MemberReviewCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val approvalKeys = words("price_band disclosures offer presenter expires_at carriage reminded mandate candidates excluded")
    private val approvalCandidateKeys = words("merchant maker ships given_by id product quantity unit_price is_exploration valence alternatives argument_against disclosure")
    private val statementKeys = words("offer household expires_at lines disclosures carriage challenge")
    private val lineKeys = words("candidate product merchant maker ships given_by valence quantity unit_price amount disclosure")
    /** Catalogue revision 3, independent of `collected_as`/`note`. */
    private val catalogueOptionalKeys = setOf("name", "variant")
    private const val CATALOGUE_NAME_MAX = 120
    private const val CATALOGUE_VARIANT_MAX = 60
    private val disclosureKeys = words("merchant product version items signature")
    private val contactKeys = setOf("kind", "value")
    private val contactKinds = setOf("email", "tel", "url")

    fun approval(bytes: ByteArray, detail: MemberOfferDetail): MemberApproval = malformed {
        val root = objectOf(bytes); require(root.keys == approvalKeys)
        val mandateJson = root.obj("mandate"); require(mandateJson.keys == words("kind scope lapses_at"))
        val mandate = MemberMandateTerms(mandateJson.string("kind"), mandateJson.string("scope"), mandateJson.nullableLong("lapses_at"))
        val band = root.nullableObject("price_band")?.let { require(it.keys == setOf("min", "max")); MemberPriceBand(it.safeLong("min"), it.safeLong("max")).also { b -> require(b.min <= b.max) } }
        val disclosures = disclosures(root.required("disclosures"))
        val rows = root.required("candidates").jsonArray.map { it.jsonObject }
        require(rows.map { it.containsKey("collected_as") }.distinct().size <= 1)
        rows.forEach { row ->
            val optional = catalogueOptionalKeys + (if (row.containsKey("collected_as")) setOf("collected_as") else emptySet())
            requireKeys(row.keys, approvalCandidateKeys, optional)
            if (row.containsKey("collected_as")) require(row.nullableString("collected_as") in setOf(null, "returned", "consumed", "missing"))
        }
        val candidates = rows.map { row ->
            MemberApprovalCandidate(
                row.string("id"), row.string("product"), row.string("merchant"), row.string("maker"), row.string("ships"), row.nullableString("given_by"),
                row.safeLong("quantity"), row.safeLong("unit_price"), row.bool("is_exploration"), row.string("valence"),
                row.required("alternatives").jsonArray.map { it.jsonPrimitive.let { p -> require(p.isString); p.content } },
                row.string("argument_against"), reference(row.obj("disclosure")),
                row.optionalCatalogueText("name", CATALOGUE_NAME_MAX), row.optionalCatalogueText("variant", CATALOGUE_VARIANT_MAX),
            )
        }
        val excluded = root.required("excluded").jsonArray.map { element ->
            val row = element.jsonObject; require(row.keys == setOf("product", "reason")); MemberExcluded(row.string("product"), row.string("reason"))
        }
        val result = MemberApproval(
            root.string("offer"), root.string("presenter"), root.safeLong("expires_at"), root.nullableLong("carriage"), band,
            disclosures, root.bool("reminded"), mandate, candidates, excluded,
        )
        require(detail.binding == "digital" && result.offer == detail.id && result.presenter == detail.presenter && result.expiresAt == detail.expiresAt) { "scope" }
        require(result.priceBand == detail.priceBand && result.disclosures == detail.disclosures && candidates.size == detail.candidates.size)
        require(mandate.kind in setOf("standing", "individual") && mandate.scope.isNotBlank() && (mandate.kind != "standing" || mandate.lapsesAt != null))
        require(candidates.map { it.id }.distinct().size == candidates.size)
        candidates.forEach { row ->
            val source = detail.candidates.singleOrNull { it.id == row.id } ?: error("candidate")
            require(matches(source, row.product, row.merchant, row.maker, row.ships, row.givenBy, row.quantity, row.unitPrice, row.valence, row.name, row.variant))
            require(row.isExploration == source.isExploration && row.alternatives.isNotEmpty() && row.alternatives.all { it.isNotBlank() } && row.argumentAgainst.isNotBlank())
            require(governs(row.disclosure, source, disclosures))
        }
        val reasons = setOf("auto_renewal", "obstructed_cancellation", "manufactured_scarcity", "late_price", "outside_mandate", "declined_before")
        require(excluded.all { it.product.isNotEmpty() && it.reason in reasons })
        result
    }

    fun statement(bytes: ByteArray, detail: MemberOfferDetail): MemberStatement = malformed {
        val root = objectOf(bytes); require(root.keys == statementKeys)
        val rows = root.required("lines").jsonArray.map { it.jsonObject }
        val hasNote = rows.firstOrNull()?.containsKey("note") == true
        val requiredLineKeys = lineKeys + (if (hasNote) setOf("note") else emptySet())
        rows.forEach { requireKeys(it.keys, requiredLineKeys, catalogueOptionalKeys) }
        val disclosures = disclosures(root.required("disclosures"))
        val lines = rows.map { row ->
            MemberStatementLine(
                row.string("candidate"), row.string("product"), row.string("merchant"), row.string("maker"), row.string("ships"), row.nullableString("given_by"),
                row.string("valence"), row.safeLong("quantity"), row.safeLong("unit_price"), row.safeLong("amount"),
                if (hasNote) row.nullableString("note") else null, reference(row.obj("disclosure")),
                row.optionalCatalogueText("name", CATALOGUE_NAME_MAX), row.optionalCatalogueText("variant", CATALOGUE_VARIANT_MAX),
            )
        }
        val result = MemberStatement(root.string("offer"), root.string("household"), root.safeLong("expires_at"), lines, disclosures, root.nullableLong("carriage"), root.string("challenge"))
        require(detail.binding == "physical" && result.offer == detail.id && result.household == detail.household && result.expiresAt == detail.expiresAt) { "scope" }
        require(disclosures == detail.disclosures)
        val eligible = detail.candidates.filter { it.valence in setOf("kept", "defaulted", "consumed") }
        val lost = detail.candidates.filter { it.valence == "lost" }
        require(lines.count { it.valence != "lost" } == eligible.size && lines.map { it.candidate }.distinct().size == lines.size)
        lines.forEach { line ->
            val source = (if (line.valence == "lost") lost else eligible).singleOrNull { it.id == line.candidate } ?: error("candidate")
            require(matches(source, line.product, line.merchant, line.maker, line.ships, line.givenBy, line.quantity, line.unitPrice, line.valence, line.name, line.variant))
            require(governs(line.disclosure, source, disclosures))
            if (line.valence == "lost") require(line.amount == 0L && !line.note.isNullOrBlank())
            else {
                require(line.note == null)
                val amount = Math.multiplyExact(source.quantity, source.unitPrice)
                require(amount in 0..Canonical.MAXIMUM_INTEGER && line.amount == if (source.givenBy == null) amount else 0L)
            }
        }
        val canonical = Canonical.statement(result.offer, result.carriage ?: 0L, lines.map { StatementLine(it.candidate, it.valence, it.amount, false) })
        require(result.challenge == Canonical.challenge(canonical))
        result
    }

    private fun disclosures(element: JsonElement): List<MemberDisclosure> = element.jsonArray.map { item ->
        val row = item.jsonObject; require(row.keys == disclosureKeys || row.keys == disclosureKeys + "contact")
        val items = row.required("items").jsonArray.map { child ->
            val value = child.jsonObject; require(value.keys == setOf("label", "value")); MemberDisclosureItem(value.string("label"), value.string("value"))
        }
        MemberDisclosure(row.string("merchant"), row.nullableString("product"), row.string("version"), items, row.string("signature"), contact(row))
    }
    /** Question 72. Absent or explicitly null is no contact; present must be exactly
     * `kind` (one of three) and `value` (non-empty, at most 256 UTF-8 bytes). */
    private fun contact(row: JsonObject): MemberDisclosureContact? {
        if (!row.containsKey("contact")) return null
        val raw = row.required("contact")
        if (raw === JsonNull) return null
        val c = raw.jsonObject; require(c.keys == contactKeys)
        val kind = c.string("kind"); require(kind in contactKinds)
        val contactValue = c.string("value"); require(contactValue.isNotEmpty() && contactValue.toByteArray(StandardCharsets.UTF_8).size <= 256)
        return MemberDisclosureContact(kind, contactValue)
    }
    private fun reference(value: JsonObject): MemberDisclosureReference { require(value.keys == setOf("merchant", "product")); return MemberDisclosureReference(value.string("merchant"), value.nullableString("product")) }
    private fun matches(source: MemberCandidate, product: String, merchant: String, maker: String, ships: String, giver: String?, quantity: Long, price: Long, valence: String, name: String?, variant: String?) =
        source.product == product && source.merchant == merchant && source.maker == maker && source.ships == ships && source.givenBy == giver && source.quantity == quantity && source.unitPrice == price && source.valence == valence && source.name == name && source.variant == variant
    private fun governs(reference: MemberDisclosureReference, source: MemberCandidate, blocks: List<MemberDisclosure>): Boolean {
        val relevant = blocks.filter { it.merchant == source.merchant }
        val product = if (relevant.any { it.product == source.product }) source.product else null
        return reference.merchant == source.merchant && reference.product == product && relevant.any { it.product == product }
    }
    private fun objectOf(bytes: ByteArray) = json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject
    private fun JsonObject.required(key: String) = getValue(key)
    private fun JsonObject.obj(key: String) = required(key).jsonObject
    private fun JsonObject.string(key: String) = required(key).jsonPrimitive.let { require(it.isString); it.content }
    private fun JsonObject.nullableString(key: String): String? = required(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(it.isString); it.content }
    private fun JsonObject.bool(key: String) = required(key).jsonPrimitive.let { require(!it.isString); it.boolean }
    private fun JsonObject.safeLong(key: String) = required(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun JsonObject.nullableLong(key: String) = required(key).takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(!it.isString); it.long }.also { require(it == null || it in 0..Canonical.MAXIMUM_INTEGER) }
    private fun JsonObject.nullableObject(key: String) = required(key).takeUnless { it === JsonNull }?.jsonObject
    /**
     * Catalogue revision 3's `name` and `variant`. Absent is legitimate; present must be a
     * nonempty string within the bound in Unicode code points, never explicit null.
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
    private fun words(value: String) = value.split(' ').toSet()
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: IllegalArgumentException) {
        if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed
    } catch (_: Exception) { throw MemberFailure.Malformed }
}

object MemberSettlementCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val keys = "offer settled_at kept_amount consumed_amount lost_amount charged disputed_amount lines payer signed_by signed_as receipt confirmation".split(' ').toSet()
    private val lineKeys = "candidate product merchant maker ships valence amount disputed".split(' ').toSet()
    private val lineOptionalKeys = setOf("name", "variant")
    private const val CATALOGUE_NAME_MAX = 120
    private const val CATALOGUE_VARIANT_MAX = 60
    fun decode(bytes: ByteArray, expectedOffer: String): ProtocolSettlement = try {
        val root = json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject; require(root.keys == keys)
        fun string(key: String): String = root.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        fun number(key: String): Long = root.getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
        val lines = root.getValue("lines").jsonArray.map { element ->
            val row = element.jsonObject
            require(lineKeys.all { it in row.keys } && (row.keys - lineKeys).all { it in lineOptionalKeys })
            fun s(key: String) = row.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
            fun catalogueText(key: String, maxCodePoints: Int): String? {
                if (!row.containsKey(key)) return null
                val text = s(key); require(text.isNotEmpty() && text.codePointCount(0, text.length) <= maxCodePoints); return text
            }
            val amount = row.getValue("amount").jsonPrimitive.let { require(!it.isString); it.long }; require(amount in 0..Canonical.MAXIMUM_INTEGER)
            ProtocolSettlementLine(
                s("candidate"), s("product"), s("merchant"), s("maker"), s("ships"), s("valence"), amount, row.getValue("disputed").jsonPrimitive.boolean,
                catalogueText("name", CATALOGUE_NAME_MAX), catalogueText("variant", CATALOGUE_VARIANT_MAX),
            )
        }
        val value = ProtocolSettlement(string("offer"), number("settled_at"), number("kept_amount"), number("consumed_amount"), number("lost_amount"), number("charged"), number("disputed_amount"), lines, string("payer"), string("signed_by"), string("signed_as"), string("receipt"), root.getValue("confirmation").takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(it.isString); it.content })
        require(value.offer == expectedOffer) { "scope" }; require(value.signedAs == "agent" && value.receipt.isNotEmpty() && lines.map { it.candidate }.distinct().size == lines.size)
        var kept = 0L; var consumed = 0L; var lost = 0L; var disputed = 0L
        fun add(total: Long, amount: Long): Long { require(total <= Canonical.MAXIMUM_INTEGER - amount); return total + amount }
        lines.forEach { line ->
            require(line.candidate.isNotEmpty() && (!line.disputed || line.valence in setOf("consumed", "lost")))
            when (line.valence) { "kept", "defaulted" -> kept = add(kept, line.amount); "consumed" -> if (line.disputed) disputed = add(disputed, line.amount) else consumed = add(consumed, line.amount); "lost" -> lost = add(lost, line.amount); else -> error("valence") }
        }
        require(value.keptAmount == kept && value.consumedAmount == consumed && value.lostAmount == lost && value.disputedAmount == disputed && value.charged == add(kept, consumed))
        value
    } catch (e: IllegalArgumentException) { if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed } catch (_: Exception) { throw MemberFailure.Malformed }
}

/**
 * §6.6, question 70. Decodes an already received GET /offers/{id}/corrections
 * response. Every failure here (a bad shape, an amount below 1, arithmetic
 * that does not close, an offer that does not match) is the caller's signal
 * to show nothing rather than to fail the settlement this reads beside.
 */
object MemberCorrectionsCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val rootKeys = setOf("offer", "original", "corrections", "net")
    private val rootKeysWithReturns = rootKeys + setOf("returns", "owed")
    private val originalKeys = setOf("charged", "carriage")
    private val correctionKeys = setOf("id", "offer", "merchant", "amount", "kind", "note", "corrected_at", "signature")
    private val returnKeys = setOf("correction", "offer", "merchant", "state", "note", "at", "signature")
    private val kinds = setOf("refund", "collection")
    private val states = setOf("returned", "repaid")

    fun decode(bytes: ByteArray, expectedOffer: String): MemberCorrections = try {
        val root = json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject
        val hasReturns = root.keys == rootKeysWithReturns
        require(hasReturns || root.keys == rootKeys)
        val originalRow = root.getValue("original").jsonObject; require(originalRow.keys == originalKeys)
        val charged = originalRow.getValue("charged").jsonPrimitive.let { require(!it.isString); it.long }; require(charged in 0..Canonical.MAXIMUM_INTEGER)
        val carriage = originalRow.getValue("carriage").takeUnless { it === JsonNull }?.jsonPrimitive?.let { require(!it.isString); it.long }
        require(carriage == null || carriage in 0..Canonical.MAXIMUM_INTEGER)
        val rows = root.getValue("corrections").jsonArray.map { it.jsonObject }
        var sum = 0L
        val ids = mutableSetOf<String>()
        val byId = mutableMapOf<String, MemberCorrection>()
        val corrections = rows.map { row ->
            require(row.keys == correctionKeys)
            fun s(key: String) = row.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
            val id = s("id"); require(id.isNotEmpty() && ids.add(id))
            val offer = s("offer"); require(offer == expectedOffer)
            val merchant = s("merchant"); require(merchant.isNotEmpty())
            val amount = row.getValue("amount").jsonPrimitive.let { require(!it.isString); it.long }; require(amount in 1..Canonical.MAXIMUM_INTEGER)
            val kind = s("kind"); require(kind in kinds)
            val note = s("note"); require(note.length <= 500)
            val correctedAt = row.getValue("corrected_at").jsonPrimitive.let { require(!it.isString); it.long }; require(correctedAt in 0..Canonical.MAXIMUM_INTEGER)
            val signature = s("signature"); require(signature.isNotEmpty())
            sum = Math.addExact(sum, amount)
            MemberCorrection(id, offer, merchant, amount, kind, note, correctedAt, signature).also { byId[id] = it }
        }
        val offer = root.getValue("offer").jsonPrimitive.let { require(it.isString); it.content }; require(offer == expectedOffer)
        val net = root.getValue("net").jsonPrimitive.let { require(!it.isString); it.long }
        val base = Math.addExact(charged, carriage ?: 0L)
        require(base in 0..Canonical.MAXIMUM_INTEGER && sum <= base && base - sum == net)
        val returnsAndOwed: Pair<List<MemberCorrectionReturn>, Long>? = if (!hasReturns) null else {
            val returnRows = root.getValue("returns").jsonArray.map { it.jsonObject }; require(returnRows.isNotEmpty())
            // At most one `returned` and one `repaid` per correction id.
            data class Slot(var returned: Long? = null, var repaid: Long? = null)
            val slots = mutableMapOf<String, Slot>()
            var lastAt = Long.MIN_VALUE
            val returns = returnRows.map { row ->
                require(row.keys == returnKeys)
                fun s(key: String) = row.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
                val correctionId = s("correction")
                val correction = byId[correctionId]; require(correction != null && correction.kind == "refund")
                val returnOffer = s("offer"); require(returnOffer == expectedOffer)
                val merchant = s("merchant"); require(merchant == correction.merchant)
                val state = s("state"); require(state in states)
                val note = s("note"); require(note.length <= 500)
                val at = row.getValue("at").jsonPrimitive.let { require(!it.isString); it.long }
                require(at in 0..Canonical.MAXIMUM_INTEGER && at >= correction.correctedAt && at >= lastAt)
                lastAt = at
                val signature = s("signature"); require(signature.isNotEmpty())
                val slot = slots.getOrPut(correctionId) { Slot() }
                if (state == "returned") { require(slot.returned == null); slot.returned = at }
                else { require(slot.repaid == null && slot.returned != null && at >= slot.returned!!); slot.repaid = at }
                MemberCorrectionReturn(correctionId, returnOffer, merchant, state, note, at, signature)
            }
            var computed = 0L
            for ((id, slot) in slots) if (slot.returned != null && slot.repaid == null) computed = Math.addExact(computed, byId.getValue(id).amount)
            val owed = root.getValue("owed").jsonPrimitive.let { require(!it.isString); it.long }
            require(owed in 0..Canonical.MAXIMUM_INTEGER && owed == computed)
            returns to owed
        }
        MemberCorrections(offer, MemberCorrectionOriginal(charged, carriage), corrections, net, returnsAndOwed?.first, returnsAndOwed?.second)
    } catch (_: Exception) { throw MemberFailure.Malformed }
}

class MemberReviews(private val sessions: MemberSessionClient) {
    suspend fun load(detail: MemberOfferDetail): MemberReview {
        val session = sessions.activeInfo()
        if (detail.household != session.household || detail.presenter !in session.presenters) throw MemberFailure.ScopeMismatch
        val path = when { detail.binding == "digital" -> "/offers/${detail.id}/approval"; detail.binding == "physical" && detail.state == "settled" -> "/offers/${detail.id}/settlement"; detail.binding == "physical" -> "/offers/${detail.id}/statement"; else -> throw MemberFailure.Malformed }
        val (reply, current) = sessions.readWithSession(path)
        if (current != session) throw MemberFailure.Superseded
        if (reply.status != 200) throw MemberFailure.Http(reply.status)
        if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed
        return when {
            detail.binding == "digital" -> MemberReview.Approval(MemberReviewCodec.approval(reply.body, detail))
            detail.state == "settled" -> MemberReview.Settlement(
                MemberSettlementCodec.decode(reply.body, detail.id).also { if (it.payer != detail.household || it.signedBy != detail.presenter) throw MemberFailure.ScopeMismatch },
                corrections(detail.id, detail.household, detail.presenter),
                detail.disclosures,
            )
            else -> MemberReview.Statement(MemberReviewCodec.statement(reply.body, detail))
        }
    }

    /**
     * §6.6, question 70. Read beside a settlement, never in its place: every
     * failure here (a 404, a malformed body, a scope mismatch, a superseded
     * or expired session) is swallowed to null, so a corrections read can
     * never make an otherwise readable settlement unreadable.
     */
    private suspend fun corrections(offerId: String, household: String, presenter: String): MemberCorrections? = try {
        val (reply, session) = sessions.readWithSession("/offers/$offerId/corrections")
        if (household != session.household || presenter !in session.presenters) null
        else if (reply.status != 200) null
        else if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") null
        else MemberCorrectionsCodec.decode(reply.body, offerId)
    } catch (_: Exception) { null }
}
