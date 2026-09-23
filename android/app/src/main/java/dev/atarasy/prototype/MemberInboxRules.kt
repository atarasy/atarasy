package dev.atarasy.prototype

/**
 * What one inbox row says, decided from the list response alone (`04b` §1b). The same rules
 * as iOS's `MemberInboxRules.swift` and the web hub's `src/shared/inbox.ts`; a row that needs
 * a second request to know its own state is a row that can be drawn wrong when the request
 * fails.
 */
sealed interface MemberRowStatus {
    /** Goods in the home, nothing to sign yet. The date is when the box is swapped (§2.2b). */
    data class AtHome(val nextSwap: Long?) : MemberRowStatus
    /** The collection found goods used or missing and nothing has settled it (§6.5).
     * `holdsNextBox` is whether this presenter's next box waits on the signature. */
    data class StatementReady(val holdsNextBox: Boolean) : MemberRowStatus
    /** A box that settled, or that closed owing nothing. */
    data class BoxClosed(val settled: Boolean) : MemberRowStatus
    /** Lines still this household's to answer. Nothing is bought if it closes (clause 32). */
    data class ProposalOpen(val closesAt: Long?) : MemberRowStatus
    /** This household has signed a set for it. */
    data object ProposalDecided : MemberRowStatus
    /** Closed with nothing chosen, withdrawn by the presenter, or settled. */
    data object ProposalClosed : MemberRowStatus
}

private val MemberOfferSummary.lines: List<MemberOfferSummaryLine> get() = candidates ?: emptyList()

/** A line the collection recorded missing. An engine before `collected_as` cannot say, so
 * such a line counts, as the web hub counts it. */
private fun missing(line: MemberOfferSummaryLine) = line.valence == "lost" && (line.collectedAs == "missing" || line.collectedAs == null)

val MemberOfferSummary.awaitsStatement: Boolean
    get() = binding == "physical" && (state == "decided" || state == "expired") &&
        lines.any { it.valence == "consumed" || missing(it) }

val MemberOfferSummary.holdsNextBox: Boolean
    get() = lines.any { it.valence == "consumed" } ||
        (lines.any(::missing) && lines.any { it.valence == "kept" || it.valence == "defaulted" })

val MemberOfferSummary.awaitsDecision: Boolean
    get() = state == "presented" && lines.any { it.valence == "offered" }

val MemberOfferSummary.rowStatus: MemberRowStatus
    get() {
        if (binding == "physical") {
            if (state == "settled") return MemberRowStatus.BoxClosed(settled = true)
            if (awaitsStatement) return MemberRowStatus.StatementReady(holdsNextBox)
            if (state == "presented") return MemberRowStatus.AtHome(expiresAt)
            return MemberRowStatus.BoxClosed(settled = false)
        }
        return when (state) {
            "presented" -> if (candidates == null || awaitsDecision) MemberRowStatus.ProposalOpen(expiresAt) else MemberRowStatus.ProposalDecided
            "decided" -> MemberRowStatus.ProposalDecided
            else -> MemberRowStatus.ProposalClosed
        }
    }

/** Whether the row asks something of the member now, which puts it in the "Waiting for you" strip. */
val MemberOfferSummary.needsMember: Boolean
    get() = when (val status = rowStatus) { is MemberRowStatus.StatementReady, is MemberRowStatus.ProposalOpen -> true; else -> false }

/** The merchants of record on this offer, in the order their lines arrive, each once. */
val MemberOfferSummary.merchants: List<String>
    get() {
        val seen = LinkedHashSet<String>()
        lines.forEach { seen.add(it.merchant) }
        return seen.toList()
    }

/**
 * `04b` §1b.2 and clause 14. One order, made once over the union of every presenter's
 * answer: newest arrival first, never grouped by presenter and never in the order the
 * session lists presenters, which is the shape that sells position. Ties fall back to the
 * offer id so two refreshes draw the same list.
 */
fun List<MemberOfferSummary>.inboxRows(binding: String): List<MemberOfferSummary> {
    val seen = HashSet<String>()
    return this.asSequence()
        .filter { it.binding == binding && seen.add(it.presenter + "\u0000" + it.id) }
        .sortedWith(compareByDescending<MemberOfferSummary> { it.arrivedAt }.thenBy { it.id })
        .toList()
}
