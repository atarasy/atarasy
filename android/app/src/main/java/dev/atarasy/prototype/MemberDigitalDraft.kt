package dev.atarasy.prototype

enum class MemberDigitalChoice { UNDECIDED, KEEP, DECLINE }
data class MemberDigitalSummary(val goods: Long, val carriage: Long, val total: Long)

class MemberDigitalDraft(val approval: MemberApproval) {
    private val choices = mutableMapOf<String, MemberDigitalChoice>()

    fun choice(candidate: String) = choices[candidate] ?: MemberDigitalChoice.UNDECIDED

    fun choose(candidate: String, choice: MemberDigitalChoice) {
        if (approval.candidates.none { it.id == candidate && it.valence == "offered" }) throw MemberFailure.Malformed
        choices[candidate] = choice
    }

    fun discard() = choices.clear()

    fun decisions(now: Long): List<Decision> {
        summary(now)
        return approval.candidates.map { candidate ->
            if (choice(candidate.id) == MemberDigitalChoice.KEEP) Decision(candidate.id, "kept", keptAs = "self")
            else Decision(candidate.id, "returned")
        }
    }

    fun summary(now: Long): MemberDigitalSummary {
        val carriage = approval.carriage
        if (now !in 0 until approval.expiresAt || approval.mandate.lapsesAt?.let { now >= it } == true ||
            approval.candidates.isEmpty() || approval.candidates.map { it.id }.distinct().size != approval.candidates.size ||
            carriage == null || carriage !in 0..Canonical.MAXIMUM_INTEGER) throw MemberFailure.Malformed
        var goods = 0L
        approval.candidates.forEach { candidate ->
            val choice = choice(candidate.id)
            if (candidate.valence != "offered" || choice == MemberDigitalChoice.UNDECIDED || candidate.quantity !in 1..Canonical.MAXIMUM_INTEGER || candidate.unitPrice !in 0..Canonical.MAXIMUM_INTEGER) throw MemberFailure.Malformed
            if (choice == MemberDigitalChoice.KEEP && candidate.givenBy == null) {
                val amount = try { Math.multiplyExact(candidate.quantity, candidate.unitPrice) } catch (_: ArithmeticException) { throw MemberFailure.Malformed }
                if (amount > Canonical.MAXIMUM_INTEGER || goods > Canonical.MAXIMUM_INTEGER - amount) throw MemberFailure.Malformed
                goods += amount
            }
        }
        if (goods > Canonical.MAXIMUM_INTEGER - carriage) throw MemberFailure.Malformed
        return MemberDigitalSummary(goods, carriage, goods + carriage)
    }
}

data class PreparedMemberDecision(
    val environment: MemberEnvironment,
    val session: MemberSessionInfo,
    val detail: MemberOfferDetail,
    val approval: MemberApproval,
    val decisions: List<Decision>,
    val canonical: String,
    val summary: MemberDigitalSummary,
) {
    companion object {
        fun create(environment: MemberEnvironment, session: MemberSessionInfo, detail: MemberOfferDetail, draft: MemberDigitalDraft, now: Long): PreparedMemberDecision {
            if (session.expiresAt <= now || detail.expiresAt <= now || detail.state != "presented" || detail.binding != "digital" ||
                session.household != detail.household || detail.presenter !in session.presenters || draft.approval.offer != detail.id || draft.approval.presenter != detail.presenter) throw MemberFailure.ScopeMismatch
            val decisions = draft.decisions(now)
            return PreparedMemberDecision(environment, session, detail, draft.approval, decisions, Canonical.decisions(detail.id, decisions), draft.summary(now))
        }
    }
}
