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
    data class Settlement(val value: ProtocolSettlement) : MemberReview
}
data class MemberDisclosureReference(val merchant: String, val product: String?)
data class MemberMandateTerms(val kind: String, val scope: String, val lapsesAt: Long?)
data class MemberApprovalCandidate(
    val id: String, val product: String, val merchant: String, val maker: String, val ships: String, val givenBy: String?,
    val quantity: Long, val unitPrice: Long, val isExploration: Boolean, val valence: String, val alternatives: List<String>,
    val argumentAgainst: String, val disclosure: MemberDisclosureReference,
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
)
data class MemberStatement(
    val offer: String, val household: String, val expiresAt: Long, val lines: List<MemberStatementLine>,
    val disclosures: List<MemberDisclosure>, val carriage: Long?, val challenge: String,
)
data class ProtocolSettlementLine(
    val candidate: String, val product: String, val merchant: String, val maker: String, val ships: String,
    val valence: String, val amount: Long, val disputed: Boolean,
)
data class ProtocolSettlement(
    val offer: String, val settledAt: Long, val keptAmount: Long, val consumedAmount: Long, val lostAmount: Long,
    val charged: Long, val disputedAmount: Long, val lines: List<ProtocolSettlementLine>, val payer: String,
    val signedBy: String, val signedAs: String, val receipt: String, val confirmation: String?,
)

object MemberReviewCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val approvalKeys = words("price_band disclosures offer presenter expires_at carriage reminded mandate candidates excluded")
    private val approvalCandidateKeys = words("merchant maker ships given_by id product quantity unit_price is_exploration valence alternatives argument_against disclosure")
    private val statementKeys = words("offer household expires_at lines disclosures carriage challenge")
    private val lineKeys = words("candidate product merchant maker ships given_by valence quantity unit_price amount disclosure")
    private val disclosureKeys = words("merchant product version items signature")

    fun approval(bytes: ByteArray, detail: MemberOfferDetail): MemberApproval = malformed {
        val root = objectOf(bytes); require(root.keys == approvalKeys)
        val mandateJson = root.obj("mandate"); require(mandateJson.keys == words("kind scope lapses_at"))
        val mandate = MemberMandateTerms(mandateJson.string("kind"), mandateJson.string("scope"), mandateJson.nullableLong("lapses_at"))
        val band = root.nullableObject("price_band")?.let { require(it.keys == setOf("min", "max")); MemberPriceBand(it.safeLong("min"), it.safeLong("max")).also { b -> require(b.min <= b.max) } }
        val disclosures = disclosures(root.required("disclosures"))
        val rows = root.required("candidates").jsonArray.map { it.jsonObject }
        require(rows.map { it.containsKey("collected_as") }.distinct().size <= 1)
        rows.forEach { row ->
            require(row.keys == approvalCandidateKeys || row.keys == approvalCandidateKeys + "collected_as")
            if (row.containsKey("collected_as")) require(row.nullableString("collected_as") in setOf(null, "returned", "consumed", "missing"))
        }
        val candidates = rows.map { row ->
            MemberApprovalCandidate(
                row.string("id"), row.string("product"), row.string("merchant"), row.string("maker"), row.string("ships"), row.nullableString("given_by"),
                row.safeLong("quantity"), row.safeLong("unit_price"), row.bool("is_exploration"), row.string("valence"),
                row.required("alternatives").jsonArray.map { it.jsonPrimitive.let { p -> require(p.isString); p.content } },
                row.string("argument_against"), reference(row.obj("disclosure")),
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
            require(matches(source, row.product, row.merchant, row.maker, row.ships, row.givenBy, row.quantity, row.unitPrice, row.valence))
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
        rows.forEach { require(it.keys == if (hasNote) lineKeys + "note" else lineKeys) }
        val disclosures = disclosures(root.required("disclosures"))
        val lines = rows.map { row ->
            MemberStatementLine(
                row.string("candidate"), row.string("product"), row.string("merchant"), row.string("maker"), row.string("ships"), row.nullableString("given_by"),
                row.string("valence"), row.safeLong("quantity"), row.safeLong("unit_price"), row.safeLong("amount"),
                if (hasNote) row.nullableString("note") else null, reference(row.obj("disclosure")),
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
            require(matches(source, line.product, line.merchant, line.maker, line.ships, line.givenBy, line.quantity, line.unitPrice, line.valence))
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
        val row = item.jsonObject; require(row.keys == disclosureKeys)
        val items = row.required("items").jsonArray.map { child ->
            val value = child.jsonObject; require(value.keys == setOf("label", "value")); MemberDisclosureItem(value.string("label"), value.string("value"))
        }
        MemberDisclosure(row.string("merchant"), row.nullableString("product"), row.string("version"), items, row.string("signature"))
    }
    private fun reference(value: JsonObject): MemberDisclosureReference { require(value.keys == setOf("merchant", "product")); return MemberDisclosureReference(value.string("merchant"), value.nullableString("product")) }
    private fun matches(source: MemberCandidate, product: String, merchant: String, maker: String, ships: String, giver: String?, quantity: Long, price: Long, valence: String) =
        source.product == product && source.merchant == merchant && source.maker == maker && source.ships == ships && source.givenBy == giver && source.quantity == quantity && source.unitPrice == price && source.valence == valence
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
    private fun words(value: String) = value.split(' ').toSet()
    private inline fun <T> malformed(block: () -> T): T = try { block() } catch (e: IllegalArgumentException) {
        if (e.message == "scope") throw MemberFailure.ScopeMismatch else throw MemberFailure.Malformed
    } catch (_: Exception) { throw MemberFailure.Malformed }
}

object MemberSettlementCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val keys = "offer settled_at kept_amount consumed_amount lost_amount charged disputed_amount lines payer signed_by signed_as receipt confirmation".split(' ').toSet()
    fun decode(bytes: ByteArray, expectedOffer: String): ProtocolSettlement = try {
        val root = json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject; require(root.keys == keys)
        fun string(key: String): String = root.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
        fun number(key: String): Long = root.getValue(key).jsonPrimitive.let { require(!it.isString); it.long }.also { require(it in 0..Canonical.MAXIMUM_INTEGER) }
        val lines = root.getValue("lines").jsonArray.map { element ->
            val row = element.jsonObject; require(row.keys == "candidate product merchant maker ships valence amount disputed".split(' ').toSet())
            fun s(key: String) = row.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
            val amount = row.getValue("amount").jsonPrimitive.let { require(!it.isString); it.long }; require(amount in 0..Canonical.MAXIMUM_INTEGER)
            ProtocolSettlementLine(s("candidate"), s("product"), s("merchant"), s("maker"), s("ships"), s("valence"), amount, row.getValue("disputed").jsonPrimitive.boolean)
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
            detail.state == "settled" -> MemberReview.Settlement(MemberSettlementCodec.decode(reply.body, detail.id).also { if (it.payer != detail.household || it.signedBy != detail.presenter) throw MemberFailure.ScopeMismatch })
            else -> MemberReview.Statement(MemberReviewCodec.statement(reply.body, detail))
        }
    }
}
