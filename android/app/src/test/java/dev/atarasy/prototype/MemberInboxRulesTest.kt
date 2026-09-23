package dev.atarasy.prototype

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same cases as iOS's `MemberInboxRuleTests` and the web hub's inbox rules. */
class MemberInboxRulesTest {
    private fun line(valence: String, collectedAs: String? = null) =
        MemberOfferSummaryLine("x", "m", null, null, null, valence, collectedAs, null, null)

    private fun offer(binding: String, state: String, lines: List<MemberOfferSummaryLine>, expires: Long? = 50): MemberOfferSummary =
        MemberOfferSummary("o", "h", "p", binding, state, presentedAt = 10, expiresAt = expires, candidates = lines)

    @Test fun `a physical box is at home until its collection leaves something to sign`() {
        assertEquals(MemberRowStatus.AtHome(50), offer("physical", "presented", listOf(line("offered"))).rowStatus)
        assertEquals(
            MemberRowStatus.StatementReady(holdsNextBox = true),
            offer("physical", "expired", listOf(line("consumed", "consumed"), line("returned", "returned"))).rowStatus,
        )
        assertEquals(MemberRowStatus.BoxClosed(settled = false), offer("physical", "expired", listOf(line("returned", "returned"))).rowStatus)
        assertEquals(MemberRowStatus.BoxClosed(settled = true), offer("physical", "settled", listOf(line("consumed"))).rowStatus)
    }

    // Question 48. A line the deadline made lost is on no statement; one recorded missing is.
    @Test fun `only a missing record puts a lost line on a statement`() {
        assertEquals(MemberRowStatus.StatementReady(holdsNextBox = false), offer("physical", "expired", listOf(line("lost"))).rowStatus)
        assertEquals(MemberRowStatus.StatementReady(holdsNextBox = false), offer("physical", "expired", listOf(line("lost", "missing"))).rowStatus)
        assertEquals(
            MemberRowStatus.StatementReady(holdsNextBox = true),
            offer("physical", "expired", listOf(line("lost", "missing"), line("kept"))).rowStatus,
        )
        val deadline = MemberOfferSummary("o", "h", "p", "physical", "expired", candidates = listOf(line("lost", "consumed")))
        assertEquals(MemberRowStatus.BoxClosed(settled = false), deadline.rowStatus)
    }

    @Test fun `a digital proposal is open only while a line is unanswered`() {
        assertEquals(MemberRowStatus.ProposalOpen(50), offer("digital", "presented", listOf(line("offered"))).rowStatus)
        assertEquals(MemberRowStatus.ProposalDecided, offer("digital", "presented", listOf(line("kept"))).rowStatus)
        assertEquals(MemberRowStatus.ProposalDecided, offer("digital", "decided", listOf(line("kept"))).rowStatus)
        assertEquals(MemberRowStatus.ProposalClosed, offer("digital", "expired", listOf(line("returned"))).rowStatus)
        assertTrue(offer("digital", "presented", listOf(line("offered"))).needsMember)
        assertFalse(offer("physical", "presented", listOf(line("offered"))).needsMember)
    }

    // 04b §1b.2, clause 14. The session's presenter order must not decide the list order.
    @Test fun `rows interleave two presenters by arrival not by session order`() {
        fun row(presenter: String, id: String, binding: String = "digital", at: Long) =
            MemberOfferSummary(id, "home", presenter, binding, "presented", presentedAt = at)
        val fromFirst = listOf(row("first", "a-old", at = 100), row("first", "a-new", at = 400))
        val fromSecond = listOf(row("second", "b-mid", at = 300), row("second", "b-box", binding = "physical", at = 200))

        val sessionOrderFirstThenSecond = fromFirst + fromSecond
        assertEquals(listOf("a-new", "b-mid", "a-old"), sessionOrderFirstThenSecond.inboxRows("digital").map { it.id })
        assertEquals(listOf("b-box"), sessionOrderFirstThenSecond.inboxRows("physical").map { it.id })

        // Listing the presenters the other way round changes nothing.
        val sessionOrderSecondThenFirst = fromSecond + fromFirst
        assertEquals(listOf("a-new", "b-mid", "a-old"), sessionOrderSecondThenFirst.inboxRows("digital").map { it.id })
    }

    @Test fun `arrivedAt falls back to expiry then zero`() {
        assertEquals(20L, MemberOfferSummary("o", "h", "p", "digital", "presented", presentedAt = 20, expiresAt = 30).arrivedAt)
        assertEquals(30L, MemberOfferSummary("o", "h", "p", "digital", "presented", presentedAt = null, expiresAt = 30).arrivedAt)
        assertEquals(0L, MemberOfferSummary("o", "h", "p", "digital", "presented").arrivedAt)
    }
}
