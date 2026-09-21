package dev.atarasy.prototype

import java.nio.file.Files
import java.util.Base64
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MemberRecoveryServiceTest {
    private val json = Json { ignoreUnknownKeys = false }
    private val root by lazy { json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-recovery-runtime.json")).readText()).jsonObject }
    private val environment = MemberEnvironment.create("test", "https://unit.example")
    private val owner by lazy { MemberSessionCodec.decodeSession(root.getValue("ownerSession").toString().toByteArray()) }
    private fun response(path: String, value: kotlinx.serialization.json.JsonElement, status: Int = 200) = MemberHttpResponse(environment.origin + path, environment.origin + path, status, "application/json", "no-store", value.toString().toByteArray())
    private fun service(session: MemberSessionInfo, replies: List<MemberHttpResponse>): Pair<MemberRecoveryService, DecisionTransport> {
        val transport = DecisionTransport(ArrayDeque(listOf(response("/auth/session", if (session == owner) root.getValue("ownerSession") else root.getValue("recovererSession"))) + replies))
        val sessions = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_800_000_000_001 }
        runBlocking { sessions.restore(session.household) }
        return MemberRecoveryService(environment, sessions, now = { 1_800_000_000_001 }) to transport
    }
    private fun assertion(ceremony: MemberRecoveryCeremony): String {
        val client = """{"type":"webauthn.get","challenge":"${ceremony.publicKey.getValue("challenge").jsonPrimitive.content}","origin":"${environment.origin}"}"""
        return """{"id":"${ceremony.credentialId}","response":{"clientDataJSON":"${Base64.getUrlEncoder().withoutPadding().encodeToString(client.toByteArray())}","authenticatorData":"YQ","signature":"YQ"}}"""
    }

    @Test fun `captured configuration request projections and notice logs validate`() {
        val participant = MemberRecoveryWire.participant(root.getValue("participant").toString().toByteArray(), root.getValue("recovererSession").jsonObject.getValue("household").jsonPrimitive.content)
        assertEquals(root.getValue("recoveryPublicKey").jsonPrimitive.content, participant.publicKey)
        val configured = MemberRecoveryWire.configuration(root.getValue("configured").toString().toByteArray(), owner.household); assertEquals(1L, configured.epoch)
        val created = MemberRecoveryWire.request(root.getValue("created"), owner.household); assertEquals("pending", created.state); assertNull(created.recovererPacket)
        val recoverer = MemberSessionCodec.decodeSession(root.getValue("recovererSession").toString().toByteArray())
        val listed = MemberRecoveryWire.requests(root.getValue("recovererList").toString().toByteArray(), recoverer.household); assertNotNull(listed.single().recovererPacket)
        assertEquals("notice_pending", MemberRecoveryWire.log(root.getValue("pendingLog").toString().toByteArray(), owner.household).events.single().state)
        assertEquals("completed", MemberRecoveryWire.log(root.getValue("finalLog").toString().toByteArray(), owner.household).events.single().state)
    }

    @Test fun `owner prepares and submits the exact recovery configuration`() = runBlocking {
        val draftRow = root.getValue("configuration").jsonObject
        val draft = MemberRecoveryConfigurationDraft(
            draftRow.getValue("epoch").jsonPrimitive.content.toLong(), draftRow.getValue("recoverer").jsonPrimitive.content,
            draftRow.getValue("keyDigest").jsonPrimitive.content, draftRow.getValue("hostShare").jsonPrimitive.content,
            draftRow.getValue("recovererPacket").jsonPrimitive.content, draftRow.getValue("noticeChannel").jsonPrimitive.content,
        )
        val recovererDigest = root.getValue("participant").jsonObject.getValue("keyDigest").jsonPrimitive.content
        val (service, transport) = service(owner, listOf(response("/member/recovery/configuration/prepare", root.getValue("preparedConfiguration")), response("/member/recovery/configuration/submit", root.getValue("configured"))))
        val prepared = service.prepareConfiguration(draft, recovererDigest)
        assertEquals(draft, prepared.draft); assertEquals("unit.example", prepared.ceremony.publicKey.getValue("rpId").jsonPrimitive.content)
        val configured = service.submitConfiguration(prepared, assertion(prepared.ceremony)); assertEquals(draft.keyDigest, configured.keyDigest)
        assertEquals(listOf("/auth/session", "/member/recovery/configuration/prepare", "/member/recovery/configuration/submit"), transport.requests.map { it.path })
    }

    @Test fun `material vault encrypts keys and shares and removes requester key`() {
        val directory = Files.createTempDirectory("atarasy-recovery-material-").toFile(); val wrapping = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
        val vault = EncryptedFileRecoveryMaterialVault(directory, AesGcmEnvelopeCipher(key = { wrapping })); val scope = "a".repeat(64)
        val agreement = vault.agreementKey(scope, true)!!; assertEquals(agreement, vault.agreementKey(scope, false))
        val requester = vault.requesterKey(scope, true)!!; assertEquals(requester, vault.requesterKey(scope, false))
        val share = MemberRecoveryShares.split(ByteArray(32) { it.toByte() }).first(); vault.saveDeviceShare(scope, 1, share); assertEquals(share, vault.deviceShare(scope, 1))
        val hosted = directory.listFiles()!!.flatMap { it.readBytes().asIterable() }.toByteArray().toString(Charsets.UTF_8)
        assertFalse(hosted.contains(agreement.publicKey)); assertFalse(hosted.contains(MemberPrivateNodeCodec.b64(share.bytes)))
        vault.removeRequesterKey(scope); assertNull(vault.requesterKey(scope, false)); assertNotNull(vault.agreementKey(scope, false))
        val wrong = EncryptedFileRecoveryMaterialVault(directory, AesGcmEnvelopeCipher(key = { SecretKeySpec(ByteArray(32) { 9 }, "AES") }))
        assertThrows(MemberFailure.Storage::class.java) { wrong.agreementKey(scope, false) }
        directory.deleteRecursively()
    }
}
