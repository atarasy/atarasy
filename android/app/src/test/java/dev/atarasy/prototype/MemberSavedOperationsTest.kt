package dev.atarasy.prototype

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MemberSavedOperationsTest {
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val session = MemberSessionInfo("session", "house", listOf("merchant"), 5_000)
    private fun handle(id: String, profile: String = MEMBER_DECISION_PROFILE, household: String = "house", presenter: String = "merchant", expiry: Long = 4_000) = MemberOperationHandle(
        id, profile, environment.name, environment.origin, "old-session", household, presenter, "offer", "canonical", expiry,
        "a".repeat(64), "b".repeat(64), "C".repeat(43), "credential", digitalTermsDigest = if (profile == MEMBER_DECISION_PROFILE) "d".repeat(64) else null,
    )

    @Test fun `saved list reveals only current household presenter and supported operations`() = runBlocking {
        fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", """{"id":"session","household":"house","presenters":["merchant"],"expiresAt":5000}"""))))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_000 }; sessions.restore("house")
        val rows = listOf(
            handle("11111111-1111-4111-8111-111111111111", expiry = 3_000),
            handle("22222222-2222-4222-8222-222222222222", MEMBER_STATEMENT_PROFILE, expiry = 4_000),
            handle("33333333-3333-4333-8333-333333333333", household = "foreign"),
            handle("44444444-4444-4444-8444-444444444444", presenter = "foreign"),
            handle("55555555-5555-4555-8555-555555555555", "atarasy.member-withdrawal-authorisation.1"),
        )
        val store = object : MemberOperationStore {
            override fun save(handle: MemberOperationHandle) = Unit; override fun load(id: String) = rows.firstOrNull { it.id == id }
            override fun handles() = rows; override fun claim(handle: MemberOperationHandle, signature: String) = Unit
        }
        val decisions = MemberDecisionOperations(environment, sessions, store, now = { 1_000 })
        val statements = MemberStatementOperations(environment, sessions, store, now = { 1_000 })
        val withdrawals = MemberWithdrawalOperations(environment, sessions, store, decisions, now = { 1_000 })
        val listed = MemberSavedOperations(environment, sessions, store, decisions, statements, withdrawals).list(session)
        assertEquals(listOf("22222222-2222-4222-8222-222222222222", "55555555-5555-4555-8555-555555555555", "11111111-1111-4111-8111-111111111111"), listed.map { it.id })
    }

    @Test fun `journal failure never becomes an empty successful list`() = runBlocking {
        fun response(path: String, body: String) = MemberHttpResponse(environment.origin + path, environment.origin + path, 200, "application/json", "no-store", body.toByteArray())
        val sessions = MemberSessionClient(environment, DecisionTransport(ArrayDeque(listOf(response("/auth/session", """{"id":"session","household":"house","presenters":["merchant"],"expiresAt":5000}""")))), DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_000 }; sessions.restore("house")
        val store = object : MemberOperationStore {
            override fun save(handle: MemberOperationHandle) = Unit; override fun load(id: String): MemberOperationHandle? = null
            override fun handles(): List<MemberOperationHandle> = throw MemberFailure.Storage; override fun claim(handle: MemberOperationHandle, signature: String) = Unit
        }
        val decisions = MemberDecisionOperations(environment, sessions, store)
        val service = MemberSavedOperations(environment, sessions, store, decisions, MemberStatementOperations(environment, sessions, store), MemberWithdrawalOperations(environment, sessions, store, decisions))
        assertThrows(MemberFailure.Storage::class.java) { runBlocking { service.list(session) } }
        Unit
    }
}
