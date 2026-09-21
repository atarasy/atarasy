package dev.atarasy.prototype

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.nio.charset.StandardCharsets

data class MemberSessionInfo(val id: String, val household: String, val presenters: List<String>, val expiresAt: Long)
data class StoredMemberSession(val token: String, val info: MemberSessionInfo)

sealed class MemberFailure(message: String) : Exception(message) {
    data object Malformed : MemberFailure("Malformed member response")
    data object ScopeMismatch : MemberFailure("Member response scope mismatch")
    data object Expired : MemberFailure("Member session expired")
    data object Superseded : MemberFailure("Member request superseded")
    data object Busy : MemberFailure("Member authentication already in progress")
    data object Storage : MemberFailure("Member storage unavailable")
    data object Unavailable : MemberFailure("Member service unavailable")
    data object UncertainVerification : MemberFailure("Member verification outcome is uncertain")
    data object RemoteLogoutUnconfirmed : MemberFailure("Remote logout unconfirmed")
    data class Http(val status: Int) : MemberFailure("Member service returned $status")
}

interface MemberSessionVault {
    fun load(environment: MemberEnvironment, household: String): StoredMemberSession?
    fun save(environment: MemberEnvironment, session: StoredMemberSession)
    fun remove(environment: MemberEnvironment, household: String)
}

object MemberSessionCodec {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val sessionKeys = setOf("id", "household", "presenters", "expiresAt")
    private val storedKeys = setOf("profile", "environment", "origin", "token", "session")

    fun decodeSession(bytes: ByteArray): MemberSessionInfo {
        val value = try { json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        if (value.keys != sessionKeys) throw MemberFailure.Malformed
        return try {
            MemberSessionInfo(
                id = value.string("id"),
                household = value.string("household"),
                presenters = value.getValue("presenters").jsonArray.map { item -> item.jsonPrimitive.let { require(it.isString); it.content } },
                expiresAt = value.getValue("expiresAt").jsonPrimitive.let { require(!it.isString); it.long },
            )
        } catch (_: Exception) { throw MemberFailure.Malformed }
    }

    fun encodeStored(environment: MemberEnvironment, value: StoredMemberSession): ByteArray = buildJsonObject {
        put("profile", JsonPrimitive("atarasy.android-session.1"))
        put("environment", JsonPrimitive(environment.name))
        put("origin", JsonPrimitive(environment.origin))
        put("token", JsonPrimitive(value.token))
        put("session", sessionJson(value.info))
    }.toString().toByteArray(StandardCharsets.UTF_8)

    fun decodeStored(environment: MemberEnvironment, bytes: ByteArray): StoredMemberSession {
        val value = try { json.parseToJsonElement(bytes.toString(StandardCharsets.UTF_8)).jsonObject } catch (_: Exception) { throw MemberFailure.Storage }
        if (value.keys != storedKeys || value["profile"]?.jsonPrimitive?.content != "atarasy.android-session.1" ||
            value["environment"]?.jsonPrimitive?.content != environment.name || value["origin"]?.jsonPrimitive?.content != environment.origin) throw MemberFailure.Storage
        val token = try { value.string("token") } catch (_: Exception) { throw MemberFailure.Storage }
        val info = try { decodeSession(value.getValue("session").toString().toByteArray(StandardCharsets.UTF_8)) } catch (_: Exception) { throw MemberFailure.Storage }
        return StoredMemberSession(token, info)
    }

    private fun sessionJson(value: MemberSessionInfo): JsonObject = buildJsonObject {
        put("id", JsonPrimitive(value.id)); put("household", JsonPrimitive(value.household))
        put("presenters", buildJsonArray { value.presenters.forEach { add(JsonPrimitive(it)) } })
        put("expiresAt", JsonPrimitive(value.expiresAt))
    }
    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
}

class MemberSessionClient(
    private val environment: MemberEnvironment,
    private val transport: MemberHttpTransport,
    private val vault: MemberSessionVault,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val mutex = Mutex()
    private var generation = 0L
    private var active: StoredMemberSession? = null
    private var authenticating = false

    suspend fun lockLocalAccess() = mutex.withLock { generation++; active = null }

    suspend fun enrollmentOptions(invitation: String): MemberCeremony {
        val body = try { MemberAuthenticationWire.invitationBody(invitation) } catch (_: Exception) { throw MemberFailure.Malformed }
        val started = mutex.withLock { generation }
        val reply = send(MemberHttpRequest("/auth/enrollment/options", body = body))
        mutex.withLock { if (generation != started) throw MemberFailure.Superseded }
        return decodeCeremonyReply(reply, registration = true)
    }

    suspend fun loginOptions(): MemberCeremony {
        val started = mutex.withLock { generation }
        val reply = send(MemberHttpRequest("/auth/login/options", body = "{}".toByteArray()))
        mutex.withLock { if (generation != started) throw MemberFailure.Superseded }
        return decodeCeremonyReply(reply, registration = false)
    }

    suspend fun finishEnrollment(ceremony: MemberCeremony, responseJson: String) {
        MemberAuthenticationWire.validate(ceremony, environment, registration = true, now = now())
        val body = MemberAuthenticationWire.verificationBody(ceremony, responseJson)
        val reply = try { send(MemberHttpRequest("/auth/enrollment/verify", body = body)) } catch (failure: MemberFailure.Http) { throw failure } catch (_: Exception) { throw MemberFailure.UncertainVerification }
        if (reply.status != 201) throw MemberFailure.Http(reply.status)
        if (!jsonResponse(reply) || !MemberAuthenticationWire.registered(reply.body)) throw MemberFailure.UncertainVerification
    }

    suspend fun finishLogin(ceremony: MemberCeremony, responseJson: String): MemberSessionInfo {
        MemberAuthenticationWire.validate(ceremony, environment, registration = false, now = now())
        val body = MemberAuthenticationWire.verificationBody(ceremony, responseJson)
        val started = mutex.withLock {
            if (authenticating) throw MemberFailure.Busy
            authenticating = true; generation++; active = null; generation
        }
        try {
            val verified = send(MemberHttpRequest("/auth/login/verify", body = body))
            if (verified.status != 200) throw MemberFailure.Http(verified.status)
            if (!jsonResponse(verified)) throw MemberFailure.UncertainVerification
            val grant = MemberAuthenticationWire.grant(verified.body)
            if (!validToken(grant.token) || grant.expiresAt <= now() || grant.expiresAt > Canonical.MAXIMUM_INTEGER || grant.id.isEmpty()) throw MemberFailure.Malformed
            val sessionReply = send(MemberHttpRequest("/auth/session", token = grant.token))
            val info = decodeSessionReply(sessionReply)
            if (!valid(info) || info.id != grant.id || info.expiresAt != grant.expiresAt) throw MemberFailure.ScopeMismatch
            val stored = StoredMemberSession(grant.token, info)
            mutex.withLock {
                if (generation != started) throw MemberFailure.Superseded
                try { vault.save(environment, stored) } catch (_: Exception) { throw MemberFailure.Storage }
                active = stored
            }
            return info
        } catch (failure: MemberFailure.Superseded) { throw failure }
        catch (failure: MemberFailure.Storage) { throw failure }
        catch (failure: MemberFailure.Http) { throw failure }
        catch (_: Exception) { throw MemberFailure.UncertainVerification }
        finally { mutex.withLock { authenticating = false } }
    }

    suspend fun restore(household: String): MemberSessionInfo? {
        require(household.isNotEmpty() && household.length <= 512 && household.none { it.code < 0x20 || it.code == 0x7f })
        val started = mutex.withLock { generation++; active = null; generation }
        val saved = try { vault.load(environment, household) } catch (_: Exception) { throw MemberFailure.Storage } ?: return null
        if (!validToken(saved.token) || !valid(saved.info) || saved.info.household != household) {
            mutex.withLock { if (generation != started) throw MemberFailure.Superseded; remove(household) }
            throw MemberFailure.Expired
        }
        val reply = send(MemberHttpRequest("/auth/session", token = saved.token))
        mutex.withLock { if (generation != started) throw MemberFailure.Superseded }
        if (reply.status == 401) {
            mutex.withLock { if (generation != started) throw MemberFailure.Superseded; remove(household) }
            throw MemberFailure.Http(401)
        }
        val info = decodeSessionReply(reply)
        if (!valid(info) || info.id != saved.info.id || info.household != household || info.expiresAt != saved.info.expiresAt) throw MemberFailure.ScopeMismatch
        val current = StoredMemberSession(saved.token, info)
        mutex.withLock {
            if (generation != started) throw MemberFailure.Superseded
            try { vault.save(environment, current) } catch (_: Exception) { throw MemberFailure.Storage }
            active = current
        }
        return info
    }

    suspend fun logout(): Boolean {
        val old = mutex.withLock {
            generation++; val result = active ?: return false
            active = null; remove(result.info.household); result
        }
        val reply = try { send(MemberHttpRequest("/auth/logout", body = "{}".toByteArray(), token = old.token)) } catch (_: Exception) { throw MemberFailure.RemoteLogoutUnconfirmed }
        if (reply.status != 204 || reply.body.isNotEmpty()) throw MemberFailure.RemoteLogoutUnconfirmed
        return true
    }

    suspend fun read(path: String, query: List<Pair<String, String>> = emptyList()): MemberHttpResponse {
        val snapshot = mutex.withLock { active to generation }
        val session = snapshot.first ?: throw MemberFailure.Expired
        if (!valid(session.info)) {
            mutex.withLock {
                if (generation != snapshot.second || active != session) throw MemberFailure.Superseded
                remove(session.info.household); generation++; active = null
            }
            throw MemberFailure.Expired
        }
        val reply = send(MemberHttpRequest(path, query = query, token = session.token))
        mutex.withLock { if (generation != snapshot.second || active != session) throw MemberFailure.Superseded }
        if (reply.status == 401) {
            mutex.withLock {
                if (generation != snapshot.second || active != session) throw MemberFailure.Superseded
                remove(session.info.household); generation++; active = null
            }
            throw MemberFailure.Http(401)
        }
        return reply
    }

    private suspend fun send(request: MemberHttpRequest): MemberHttpResponse {
        val reply = try { transport.send(request) } catch (failure: MemberFailure) { throw failure } catch (_: Exception) { throw MemberFailure.Unavailable }
        if (reply.requestedUrl != reply.responseUrl) throw MemberFailure.ScopeMismatch
        if (reply.cacheControl?.split(',')?.map { it.trim().lowercase() }?.contains("no-store") != true) throw MemberFailure.Malformed
        return reply
    }
    private fun decodeSessionReply(reply: MemberHttpResponse): MemberSessionInfo {
        if (reply.status != 200) throw MemberFailure.Http(reply.status)
        if (reply.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw MemberFailure.Malformed
        return MemberSessionCodec.decodeSession(reply.body)
    }
    private fun decodeCeremonyReply(reply: MemberHttpResponse, registration: Boolean): MemberCeremony {
        if (reply.status != 200) throw MemberFailure.Http(reply.status)
        if (!jsonResponse(reply)) throw MemberFailure.Malformed
        return MemberAuthenticationWire.ceremony(reply.body, environment, registration, now())
    }
    private fun jsonResponse(reply: MemberHttpResponse) = reply.contentType?.substringBefore(';')?.trim()?.lowercase() == "application/json"
    private fun validToken(value: String) = Regex("^amr1_[A-Za-z0-9_-]{43}$").matches(value)
    private fun valid(value: MemberSessionInfo): Boolean = value.id.isNotEmpty() && value.id.length <= 512 && value.household.isNotEmpty() && value.household.length <= 512 &&
        value.expiresAt > now() && value.expiresAt <= Canonical.MAXIMUM_INTEGER && value.presenters.size <= 512 && value.presenters.distinct().size == value.presenters.size && value.presenters.all { it.isNotEmpty() && it.length <= 512 }
    private fun remove(household: String) { try { vault.remove(environment, household) } catch (_: Exception) { throw MemberFailure.Storage } }
}
