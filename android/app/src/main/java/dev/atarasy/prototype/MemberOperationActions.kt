package dev.atarasy.prototype

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class MemberOperationActions(
    private val environment: MemberEnvironment,
    private val sessions: MemberSessionClient,
) {
    suspend fun cancel(handle: MemberOperationHandle) {
        val active = sessions.activeInfo()
        if (handle.operationProfile !in setOf(MEMBER_DECISION_PROFILE, MEMBER_STATEMENT_PROFILE, MEMBER_WITHDRAWAL_PROFILE) || handle.attempted ||
            handle.environment != environment.name || handle.origin != environment.origin || handle.household != active.household || handle.presenter !in active.presenters) throw MemberFailure.ScopeMismatch
        val (reply, current) = sessions.readWithSession("/member/operations/${handle.id}/cancel", body = "{}".toByteArray())
        if (current != active) throw MemberFailure.Superseded
        if (reply.status != 200) throw MemberFailure.Http(reply.status)
        if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed
        val root = try { Json.parseToJsonElement(reply.body.toString(Charsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        val cancelled = try { root.getValue("cancelled").jsonPrimitive.let { !it.isString && it.content.toBooleanStrictOrNull() == true } } catch (_: Exception) { false }
        if (root.keys != setOf("cancelled") || !cancelled) throw MemberFailure.Malformed
    }
}
