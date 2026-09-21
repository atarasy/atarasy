package dev.atarasy.prototype

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MemberDigitalDraftTest {
    private val json = Json { ignoreUnknownKeys = false }
    private val root by lazy { json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-review-responses.json")).readText()).jsonObject }
    private fun value(name: String) = root["cases"]!!.jsonArray.first { it.jsonObject["name"]!!.jsonPrimitive.content == name }.jsonObject["value"]!!.jsonObject
    private val detail by lazy { value("digital-detail").let { MemberOfferCodec.detail(it.toString().toByteArray(), it["id"]!!.jsonPrimitive.content, "detail-house") } }
    private val approval by lazy { MemberReviewCodec.approval(value("digital-known-carriage").toString().toByteArray(), detail) }

    @Test fun `complete choices calculate goods carriage total and canonical decisions`() {
        val draft = MemberDigitalDraft(approval)
        draft.choose(approval.candidates[0].id, MemberDigitalChoice.KEEP)
        draft.choose(approval.candidates[1].id, MemberDigitalChoice.KEEP)
        assertEquals(MemberDigitalSummary(2400, 0, 2400), draft.summary(1_700_000_000_000))
        assertEquals(listOf("kept", "kept"), draft.decisions(1_700_000_000_000).map { it.valence })
        assertEquals(listOf("self", "self"), draft.decisions(1_700_000_000_000).map { it.keptAs })
    }

    @Test fun `gift and declined goods never add a charge`() {
        val draft = MemberDigitalDraft(approval)
        draft.choose(approval.candidates[0].id, MemberDigitalChoice.DECLINE)
        draft.choose(approval.candidates[1].id, MemberDigitalChoice.KEEP)
        assertEquals(MemberDigitalSummary(0, 0, 0), draft.summary(1_700_000_000_000))
    }

    @Test fun `incomplete expired unknown carriage and foreign candidate fail closed`() {
        val draft = MemberDigitalDraft(approval)
        assertThrows(MemberFailure.Malformed::class.java) { draft.summary(1_700_000_000_000) }
        assertThrows(MemberFailure.Malformed::class.java) { draft.choose("foreign", MemberDigitalChoice.KEEP) }
        approval.candidates.forEach { draft.choose(it.id, MemberDigitalChoice.DECLINE) }
        assertThrows(MemberFailure.Malformed::class.java) { draft.summary(approval.expiresAt) }
        val unknown = MemberReviewCodec.approval(value("digital-unknown-carriage").toString().toByteArray(), detail)
        val noCarriage = MemberDigitalDraft(unknown); unknown.candidates.forEach { noCarriage.choose(it.id, MemberDigitalChoice.DECLINE) }
        assertThrows(MemberFailure.Malformed::class.java) { noCarriage.summary(1_700_000_000_000) }
    }

    @Test fun `prepared decision binds session offer approval and canonical choices`() {
        val draft = MemberDigitalDraft(approval); approval.candidates.forEach { draft.choose(it.id, MemberDigitalChoice.DECLINE) }
        val session = MemberSessionInfo("session", detail.household, listOf(detail.presenter), 1_800_000_000_000)
        val prepared = PreparedMemberDecision.create(MemberEnvironment.create("test", "https://unit.example"), session, detail, draft, 1_700_000_000_000)
        assertEquals(Canonical.decisions(detail.id, draft.decisions(1_700_000_000_000)), prepared.canonical)
        assertThrows(MemberFailure.ScopeMismatch::class.java) { PreparedMemberDecision.create(prepared.environment, session.copy(household = "foreign"), detail, draft, 1_700_000_000_000) }
    }
}
