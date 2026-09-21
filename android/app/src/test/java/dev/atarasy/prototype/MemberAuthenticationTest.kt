package dev.atarasy.prototype

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private class AuthVault : MemberSessionVault {
    var stored: StoredMemberSession? = null
    override fun load(environment: MemberEnvironment, household: String) = stored
    override fun save(environment: MemberEnvironment, session: StoredMemberSession) { stored = session }
    override fun remove(environment: MemberEnvironment, household: String) { stored = null }
}

private class AuthTransport(private val replies: MutableList<MemberHttpResponse>) : MemberHttpTransport {
    val requests = mutableListOf<MemberHttpRequest>()
    override suspend fun send(request: MemberHttpRequest): MemberHttpResponse { requests += request; return replies.removeAt(0) }
}

class MemberAuthenticationTest {
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val ceremonyId = "2638e7c9-a994-49e6-ad4d-feecffff51fe"
    private val token = "amr1_" + "A".repeat(43)
    private fun reply(path: String, body: String, status: Int = 200) = MemberHttpResponse(
        environment.origin + path, environment.origin + path, status, "application/json", "no-store", body.toByteArray(),
    )
    private fun loginOptions(rp: String = "unit.example") = """{
      "id":"$ceremonyId", "expiresAt":2000,
      "publicKey" : { "challenge":"${"A".repeat(43)}", "rpId":"$rp", "timeout":1000, "userVerification":"required", "allowCredentials":[] }
    }"""
    private fun registrationOptions() = """{
      "id":"47607007-c4b9-46b8-810b-df23989eddeb","expiresAt":2000,
      "publicKey":{"challenge":"${"B".repeat(43)}","rp":{"name":"Atarasy","id":"unit.example"},"user":{"id":"dXNlcg","name":"member","displayName":""},"pubKeyCredParams":[{"alg":-7,"type":"public-key"}],"timeout":1000,"attestation":"none","excludeCredentials":[],"authenticatorSelection":{"residentKey":"required","userVerification":"required","requireResidentKey":true},"extensions":{"credProps":true},"hints":[]}
    }"""

    @Test fun `ceremony keeps exact public key JSON and validates pinned RP requirements`() {
        val source = loginOptions()
        val ceremony = MemberAuthenticationWire.ceremony(source.toByteArray(), environment, false, 1000)
        assertEquals("{ \"challenge\":\"${"A".repeat(43)}\", \"rpId\":\"unit.example\", \"timeout\":1000, \"userVerification\":\"required\", \"allowCredentials\":[] }", ceremony.publicKeyJson)
        assertThrows(MemberFailure.ScopeMismatch::class.java) { MemberAuthenticationWire.ceremony(loginOptions("foreign.example").toByteArray(), environment, false, 1000) }
        assertThrows(MemberFailure.Malformed::class.java) { MemberAuthenticationWire.ceremony(loginOptions().replace("\"expiresAt\":2000", "\"expiresAt\":\"2000\"").toByteArray(), environment, false, 1000) }
    }

    @Test fun `registration contract requires discoverable verified ES256 options`() {
        val ceremony = MemberAuthenticationWire.ceremony(registrationOptions().toByteArray(), environment, true, 1000)
        assertTrue(ceremony.registration)
        for (changed in listOf(
            registrationOptions().replace("\"residentKey\":\"required\"", "\"residentKey\":\"preferred\""),
            registrationOptions().replace("\"alg\":-7", "\"alg\":-257"),
            registrationOptions().replace("\"credProps\":true", "\"credProps\":false"),
        )) assertThrows(MemberFailure::class.java) { MemberAuthenticationWire.ceremony(changed.toByteArray(), environment, true, 1000) }
    }

    @Test fun `login verifies grant then session and persists only their exact common authority`() = runBlocking {
        val session = """{"id":"session-id","household":"key:house","presenters":["merchant"],"expiresAt":5000}"""
        val transport = AuthTransport(mutableListOf(
            reply("/auth/login/options", loginOptions()),
            reply("/auth/login/verify", """{"id":"session-id","token":"$token","expiresAt":5000}"""),
            reply("/auth/session", session),
        ))
        val vault = AuthVault(); val client = MemberSessionClient(environment, transport, vault) { 1000 }
        val ceremony = client.loginOptions()
        val result = client.finishLogin(ceremony, """{"id":"credential","rawId":"credential","type":"public-key","clientExtensionResults":{},"response":{"clientDataJSON":"AA","authenticatorData":"AA","signature":"AA","userHandle":"AA"}}""")
        assertEquals("key:house", result.household); assertEquals(result, vault.stored?.info)
        assertEquals(listOf("/auth/login/options", "/auth/login/verify", "/auth/session"), transport.requests.map { it.path })
        assertEquals("{}", transport.requests[0].body!!.toString(Charsets.UTF_8))
        assertEquals(token, transport.requests[2].token)
    }

    @Test fun `registration submits the invited ceremony and accepts only exact success`() = runBlocking {
        val invitation = "aen1_" + "C".repeat(43)
        val transport = AuthTransport(mutableListOf(
            reply("/auth/enrollment/options", registrationOptions()),
            reply("/auth/enrollment/verify", """{"registered":true}""", 201),
        ))
        val client = MemberSessionClient(environment, transport, AuthVault()) { 1000 }
        val ceremony = client.enrollmentOptions(invitation)
        client.finishEnrollment(ceremony, """{"id":"credential","rawId":"credential","type":"public-key","clientExtensionResults":{},"response":{"clientDataJSON":"AA","attestationObject":"AA"}}""")
        assertTrue(transport.requests[0].body!!.toString(Charsets.UTF_8).contains(invitation))
        assertEquals(listOf("/auth/enrollment/options", "/auth/enrollment/verify"), transport.requests.map { it.path })
    }

    @Test fun `changed grant session and response loss never create local authority`() = runBlocking {
        val options = MemberAuthenticationWire.ceremony(loginOptions().toByteArray(), environment, false, 1000)
        val mismatch = AuthTransport(mutableListOf(
            reply("/auth/login/verify", """{"id":"first","token":"$token","expiresAt":5000}"""),
            reply("/auth/session", """{"id":"other","household":"key:house","presenters":[],"expiresAt":5000}"""),
        ))
        val mismatchVault = AuthVault(); val mismatchClient = MemberSessionClient(environment, mismatch, mismatchVault) { 1000 }
        assertThrows(MemberFailure.UncertainVerification::class.java) { runBlocking { mismatchClient.finishLogin(options, "{}") } }
        assertEquals(null, mismatchVault.stored)

        val lost = object : MemberHttpTransport { override suspend fun send(request: MemberHttpRequest): MemberHttpResponse = throw java.io.IOException("lost") }
        val lostVault = AuthVault(); val lostClient = MemberSessionClient(environment, lost, lostVault) { 1000 }
        assertThrows(MemberFailure.UncertainVerification::class.java) { runBlocking { lostClient.finishLogin(options, "{}") } }
        assertEquals(null, lostVault.stored)
    }
}
