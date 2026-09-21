package dev.atarasy.prototype

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.nio.charset.StandardCharsets
import java.util.UUID

data class MemberCeremony(
    val id: String,
    val expiresAt: Long,
    val publicKeyJson: String,
    val registration: Boolean,
)

data class MemberSessionGrant(val id: String, val token: String, val expiresAt: Long)

sealed interface MemberAuthenticationResult {
    data class SignedIn(val session: MemberSessionInfo) : MemberAuthenticationResult
    data object Registered : MemberAuthenticationResult
    data object Cancelled : MemberAuthenticationResult
    data object NoCredential : MemberAuthenticationResult
    data class Failed(val failure: MemberFailure) : MemberAuthenticationResult
}

object MemberAuthenticationWire {
    private val json = Json { ignoreUnknownKeys = false; isLenient = false }
    private val ceremonyKeys = setOf("id", "expiresAt", "publicKey")

    fun invitationBody(invitation: String): ByteArray {
        require(Regex("^aen1_[A-Za-z0-9_-]{43}$").matches(invitation))
        return buildJsonObject { put("invitation", JsonPrimitive(invitation)) }.toString().toByteArray()
    }

    fun ceremony(bytes: ByteArray, environment: MemberEnvironment, registration: Boolean, now: Long): MemberCeremony {
        val text = bytes.toString(StandardCharsets.UTF_8)
        val root = objectValue(text)
        if (root.keys != ceremonyKeys) throw MemberFailure.Malformed
        val id = root.string("id"); val expiresAt = root.long("expiresAt")
        if (!canonicalUuid(id) || expiresAt <= now || expiresAt > Canonical.MAXIMUM_INTEGER) throw MemberFailure.Malformed
        val publicKey = try { root.getValue("publicKey").jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
        val rawPublicKey = rawObjectMember(text, "publicKey") ?: throw MemberFailure.Malformed
        if (registration) validateRegistration(publicKey, environment) else validateAuthentication(publicKey, environment)
        return MemberCeremony(id, expiresAt, rawPublicKey, registration)
    }

    fun verificationBody(ceremony: MemberCeremony, responseJson: String): ByteArray {
        val response = objectValue(responseJson)
        if (responseJson.toByteArray().size > 1_048_576) throw MemberFailure.Malformed
        return buildJsonObject { put("id", JsonPrimitive(ceremony.id)); put("response", response) }.toString().toByteArray()
    }

    fun registered(bytes: ByteArray): Boolean {
        val value = objectValue(bytes.toString(StandardCharsets.UTF_8))
        return value.keys == setOf("registered") && value["registered"] == JsonPrimitive(true)
    }

    fun grant(bytes: ByteArray): MemberSessionGrant {
        val value = objectValue(bytes.toString(StandardCharsets.UTF_8))
        if (value.keys != setOf("id", "token", "expiresAt")) throw MemberFailure.Malformed
        return MemberSessionGrant(value.string("id"), value.string("token"), value.long("expiresAt"))
    }

    fun validate(ceremony: MemberCeremony, environment: MemberEnvironment, registration: Boolean, now: Long) {
        if (ceremony.registration != registration || !canonicalUuid(ceremony.id) || ceremony.expiresAt <= now || ceremony.expiresAt > Canonical.MAXIMUM_INTEGER) throw MemberFailure.Expired
        val publicKey = objectValue(ceremony.publicKeyJson)
        if (registration) validateRegistration(publicKey, environment) else validateAuthentication(publicKey, environment)
    }

    private fun validateAuthentication(value: JsonObject, environment: MemberEnvironment) {
        if (value.keys != setOf("challenge", "rpId", "timeout", "userVerification", "allowCredentials") ||
            value.string("rpId") != environment.relyingPartyId || value.string("userVerification") != "required" || value.getValue("allowCredentials").jsonArray.isNotEmpty()) throw MemberFailure.ScopeMismatch
        challengeAndTimeout(value)
    }

    private fun validateRegistration(value: JsonObject, environment: MemberEnvironment) {
        if (value.keys != setOf("challenge", "rp", "user", "pubKeyCredParams", "timeout", "attestation", "excludeCredentials", "authenticatorSelection", "extensions", "hints")) throw MemberFailure.Malformed
        challengeAndTimeout(value)
        val rp = value.getValue("rp").jsonObject
        val user = value.getValue("user").jsonObject
        val selection = value.getValue("authenticatorSelection").jsonObject
        if (rp.keys != setOf("name", "id") || rp.string("id") != environment.relyingPartyId || rp.string("name").isEmpty() ||
            user.keys != setOf("id", "name", "displayName") || !base64url(user.string("id")) || user.string("name").isEmpty() ||
            value.string("attestation") != "none" || value.getValue("excludeCredentials").jsonArray.isNotEmpty() || value.getValue("hints").jsonArray.isNotEmpty() ||
            selection.keys != setOf("residentKey", "userVerification", "requireResidentKey") || selection.string("residentKey") != "required" ||
            selection.string("userVerification") != "required" || selection["requireResidentKey"] != JsonPrimitive(true) ||
            value.getValue("extensions").jsonObject != JsonObject(mapOf("credProps" to JsonPrimitive(true)))) throw MemberFailure.ScopeMismatch
        val algorithms = value.getValue("pubKeyCredParams").jsonArray
        if (algorithms.size != 1 || algorithms.single().jsonObject != JsonObject(mapOf("alg" to JsonPrimitive(-7), "type" to JsonPrimitive("public-key")))) throw MemberFailure.ScopeMismatch
    }

    private fun challengeAndTimeout(value: JsonObject) {
        if (!Regex("^[A-Za-z0-9_-]{43}$").matches(value.string("challenge"))) throw MemberFailure.Malformed
        val timeout = value.long("timeout"); if (timeout !in 1..3_600_000) throw MemberFailure.Malformed
    }
    private fun objectValue(text: String): JsonObject = try { json.parseToJsonElement(text).jsonObject } catch (_: Exception) { throw MemberFailure.Malformed }
    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.let { if (!it.isString) throw MemberFailure.Malformed; it.content }
    private fun JsonObject.long(key: String): Long = getValue(key).jsonPrimitive.let { if (it.isString) throw MemberFailure.Malformed; try { it.long } catch (_: Exception) { throw MemberFailure.Malformed } }
    private fun base64url(value: String) = value.isNotEmpty() && Regex("^[A-Za-z0-9_-]+$").matches(value)
    private fun canonicalUuid(value: String) = try { UUID.fromString(value).toString() == value } catch (_: Exception) { false }

    /** Returns the original object substring so Credential Manager receives server whitespace and ordering unchanged. */
    internal fun rawObjectMember(text: String, wanted: String): String? {
        var index = skipSpace(text, 0); if (index >= text.length || text[index++] != '{') return null
        while (true) {
            index = skipSpace(text, index); if (index >= text.length || text[index] == '}') return null
            val keyEnd = stringEnd(text, index) ?: return null
            val key = try { json.parseToJsonElement(text.substring(index, keyEnd)).jsonPrimitive.content } catch (_: Exception) { return null }
            index = skipSpace(text, keyEnd); if (index >= text.length || text[index++] != ':') return null
            index = skipSpace(text, index); val start = index; val end = valueEnd(text, start) ?: return null
            if (key == wanted) return text.substring(start, end)
            index = skipSpace(text, end); if (index >= text.length || text[index] != ',') return null; index++
        }
    }
    private fun skipSpace(text: String, from: Int): Int { var i = from; while (i < text.length && text[i] in " \t\r\n") i++; return i }
    private fun stringEnd(text: String, from: Int): Int? {
        if (from >= text.length || text[from] != '"') return null
        var escaped = false; var i = from + 1
        while (i < text.length) { val c = text[i++]; if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') return i }
        return null
    }
    private fun valueEnd(text: String, from: Int): Int? {
        if (from >= text.length) return null
        if (text[from] == '"') return stringEnd(text, from)
        if (text[from] == '{' || text[from] == '[') {
            val opening = text[from]; val closing = if (opening == '{') '}' else ']'; var depth = 0; var i = from
            while (i < text.length) {
                if (text[i] == '"') { i = stringEnd(text, i) ?: return null; continue }
                if (text[i] == opening) depth++ else if (text[i] == closing) { depth--; if (depth == 0) return i + 1 }
                i++
            }
            return null
        }
        var i = from; while (i < text.length && text[i] !in ",}") i++; return i
    }
}

class MemberAuthenticationFlow(private val sessions: MemberSessionClient, private val passkeys: PasskeyCeremonies) {
    suspend fun signIn(): MemberAuthenticationResult {
        val ceremony = try { sessions.loginOptions() } catch (failure: MemberFailure) { return MemberAuthenticationResult.Failed(failure) }
        return when (val result = passkeys.authenticate(ceremony.publicKeyJson)) {
            is PasskeyResult.Completed -> try { MemberAuthenticationResult.SignedIn(sessions.finishLogin(ceremony, result.responseJson)) } catch (failure: MemberFailure) { MemberAuthenticationResult.Failed(failure) }
            PasskeyResult.Cancelled -> MemberAuthenticationResult.Cancelled
            PasskeyResult.Unavailable -> MemberAuthenticationResult.NoCredential
            is PasskeyResult.Failed -> MemberAuthenticationResult.Failed(MemberFailure.Unavailable)
        }
    }

    suspend fun register(invitation: String): MemberAuthenticationResult {
        val ceremony = try { sessions.enrollmentOptions(invitation) } catch (failure: MemberFailure) { return MemberAuthenticationResult.Failed(failure) }
        return when (val result = passkeys.register(ceremony.publicKeyJson)) {
            is PasskeyResult.Completed -> try { sessions.finishEnrollment(ceremony, result.responseJson); MemberAuthenticationResult.Registered } catch (failure: MemberFailure) { MemberAuthenticationResult.Failed(failure) }
            PasskeyResult.Cancelled -> MemberAuthenticationResult.Cancelled
            PasskeyResult.Unavailable -> MemberAuthenticationResult.NoCredential
            is PasskeyResult.Failed -> MemberAuthenticationResult.Failed(MemberFailure.Unavailable)
        }
    }
}
