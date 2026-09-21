package dev.atarasy.prototype

import java.nio.file.Files
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private class NodeTransport(private val environment: MemberEnvironment, private val session: MemberSessionInfo) : MemberHttpTransport {
    val records = linkedMapOf<String, MemberPrivateNodeRecord>()
    override suspend fun send(request: MemberHttpRequest): MemberHttpResponse {
        val body = when {
            request.path == "/auth/session" -> """{"id":"${session.id}","household":"${session.household}","presenters":[],"expiresAt":${session.expiresAt}}"""
            request.path == "/member/private-node/records" -> buildJsonObject {
                put("profile", JsonPrimitive("atarasy.private-node-index.1")); put("checkedAt", JsonPrimitive(1_000))
                put("records", buildJsonArray { records.values.sortedBy { it.id }.forEach { add(recordJson(it)) } })
            }.toString()
            request.path.startsWith("/member/private-node/records/") -> {
                val id = request.path.substringAfterLast('/')
                if (request.body == null) recordJson(records.getValue(id)).toString()
                else {
                    val root = Json.parseToJsonElement(request.body.toString(Charsets.UTF_8)).jsonObject
                    val expected = root.getValue("expectedRevision").jsonPrimitive.content.toLong()
                    require((records[id]?.revision ?: 0) == expected)
                    val envelope = MemberPrivateNodeCodec.envelope(root.getValue("envelope"))
                    MemberPrivateNodeRecord(id, expected + 1, 1_001, envelope).also { records[id] = it }.let(::recordJson).toString()
                }
            }
            else -> error(request.path)
        }
        return MemberHttpResponse(environment.origin + request.path, environment.origin + request.path, 200, "application/json", "no-store", body.toByteArray())
    }
    private fun recordJson(value: MemberPrivateNodeRecord) = buildJsonObject {
        put("id", JsonPrimitive(value.id)); put("revision", JsonPrimitive(value.revision)); put("updatedAt", JsonPrimitive(value.updatedAt)); put("envelope", MemberPrivateNodeCodec.envelopeJson(value.envelope))
    }
}

class MemberPrivateNodeTest {
    private val environment = MemberEnvironment.create("test", "https://unit.example")

    @Test fun `captured Swift record decrypts with the Android codec`() {
        val root = Json.parseToJsonElement(checkNotNull(javaClass.getResource("/member-private-node-runtime.json")).readText()).jsonObject
        val key = MemberPrivateNodeCodec.data(root.getValue("key").jsonPrimitive.content)
        val record = MemberPrivateNodeCodec.record(root.getValue("record"))
        val clear = MemberPrivateNodeCrypto(key).open(record, environment, root.getValue("household").jsonPrimitive.content)
        assertTrue(clear.contentEquals(MemberPrivateNodeCodec.data(root.getValue("clear").jsonPrimitive.content)))
        assertThrows(MemberFailure.Storage::class.java) { MemberPrivateNodeCrypto(ByteArray(32) { 1 }).open(record, environment, root.getValue("household").jsonPrimitive.content) }
    }

    @Test fun `node bootstraps writes locks and requires recovery when its device key is missing`() = runBlocking {
        val session = MemberSessionInfo("private-session", "key:private-household", emptyList(), 9_000)
        val transport = NodeTransport(environment, session)
        fun sessions() = MemberSessionClient(environment, transport, DecisionVault(StoredMemberSession("amr1_" + "A".repeat(43), session))) { 1_000 }
        val active = sessions(); active.restore(session.household)
        val wrappingKey = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
        val firstDirectory = Files.createTempDirectory("atarasy-node-key-").toFile()
        val vault = EncryptedFilePrivateNodeKeyVault(firstDirectory, AesGcmEnvelopeCipher(key = { wrappingKey }))
        val node = MemberPrivateNode(environment, MemberPrivateNodeRemote(active), vault)
        assertEquals(MemberPrivateNodeState.READY, node.open(session)); assertTrue(transport.records.containsKey(MemberPrivateNode.BOOTSTRAP_ID))
        val id = "22222222-2222-4222-8222-222222222222"; val clear = "private purchase and note".toByteArray()
        assertEquals(1, node.write(id = id, expectedRevision = 0, clear = clear).revision)
        assertTrue(node.read(id).contentEquals(clear)); val recoveryKey = node.recoveryKey(session)
        val target = MemberEnvironment.create("move", "https://target.example"); val move = node.prepareMove(target, session)
        assertEquals(transport.records.values.sortedBy { it.id }, move.source); assertEquals(move.source.map { it.id }, move.target.map { it.id })
        assertTrue(MemberPrivateNodeCrypto(move.key).open(move.target.single { it.id == id }, target, session.household).contentEquals(clear))
        assertFalse(move.source.single { it.id == id }.envelope == move.target.single { it.id == id }.envelope)
        assertFalse(transport.records.getValue(id).envelope.ciphertext.contains("private purchase"))
        val wrapped = firstDirectory.listFiles()!!.single().readBytes(); assertFalse(wrapped.contentEquals(recoveryKey)); assertFalse(wrapped.toString(Charsets.UTF_8).contains(session.household))
        node.lock(); assertEquals(MemberPrivateNodeState.LOCKED, node.state)
        assertThrows(MemberFailure.Storage::class.java) { runBlocking { node.read(id) } }
        val replacementSessions = sessions(); replacementSessions.restore(session.household)
        val replacementDirectory = Files.createTempDirectory("atarasy-node-replacement-").toFile()
        val replacement = MemberPrivateNode(environment, MemberPrivateNodeRemote(replacementSessions), EncryptedFilePrivateNodeKeyVault(replacementDirectory, AesGcmEnvelopeCipher(key = { wrappingKey })))
        assertEquals(MemberPrivateNodeState.RECOVERY_REQUIRED, replacement.open(session))
        assertThrows(MemberFailure.Storage::class.java) { runBlocking { replacement.installRecoveredKey(ByteArray(32) { 9 }, session) } }
        replacement.installRecoveredKey(recoveryKey, session); assertTrue(replacement.read(id).contentEquals(clear))
        firstDirectory.deleteRecursively(); replacementDirectory.deleteRecursively()
        Unit
    }
}
