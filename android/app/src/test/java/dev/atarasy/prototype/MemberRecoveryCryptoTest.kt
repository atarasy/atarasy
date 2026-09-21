package dev.atarasy.prototype

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MemberRecoveryCryptoTest {
    @Test fun `every distinct replicated share pair restores the ledger key`() {
        val key = ByteArray(32) { it.toByte() }; val shares = MemberRecoveryShares.split(key)
        assertEquals(listOf(MemberRecoveryParticipant.DEVICE, MemberRecoveryParticipant.RECOVERER, MemberRecoveryParticipant.HOST), shares.map { it.participant })
        assertTrue(MemberRecoveryShares.recover(shares[0], shares[1]).contentEquals(key))
        assertTrue(MemberRecoveryShares.recover(shares[0], shares[2]).contentEquals(key))
        assertTrue(MemberRecoveryShares.recover(shares[1], shares[2]).contentEquals(key))
        assertThrows(MemberFailure.Malformed::class.java) { MemberRecoveryShares.recover(shares[0], shares[0]) }
        val changed = shares[0].bytes.copyOf().also { it[it.lastIndex] = (it.last() + 1).toByte() }
        assertThrows(MemberFailure.Storage::class.java) { MemberRecoveryShares.recover(MemberRecoveryShare(MemberRecoveryParticipant.DEVICE, changed), shares[1]) }
        assertEquals(32, MemberPrivateNodeCodec.data(MemberRecoveryShares.digest(key)).size)
    }

    @Test fun `recovery packet is end to end encrypted and bound to exact ceremony`() {
        val recipient = MemberRecoveryPackets.generateKeyPair(); val clear = ByteArray(64) { (it * 3).toByte() }
        val context = MemberRecoveryPacketContext("recoverer-share", "owner", "recoverer", "configuration", 2)
        val packet = MemberRecoveryPackets.seal(clear, recipient.publicKey, context)
        assertTrue(MemberRecoveryPackets.open(packet, recipient, context).contentEquals(clear))
        assertThrows(MemberFailure.Storage::class.java) { MemberRecoveryPackets.open(packet, recipient, context.copy(epoch = 3)) }
        assertThrows(MemberFailure.Storage::class.java) { MemberRecoveryPackets.open(packet, MemberRecoveryPackets.generateKeyPair(), context) }
        assertEquals(32, MemberPrivateNodeCodec.data(MemberRecoveryPackets.keyDigest(recipient.publicKey)).size)
    }
}
