package dev.viasix.app.tun

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.nio.ByteBuffer

class DnsUdpResponsePolicyTest {
    @Test
    fun dnsWithoutEdnsUses512BytesAndKeepsACompleteQuestionForTcpRetry() {
        val query = query()
        val policy = DnsUdpResponsePolicy.parseQuery(query, maxUdpPayloadBytes = 1472)
        val answer = answer(query, txtBytes = 700)

        assertEquals(512, policy.udpCapacity)
        assertTruncatedReply(query, DnsUdpResponsePolicy.fitResponse(policy, answer))
    }

    @Test
    fun ednsCapacityIsRespectedAndSmallerAnswersRemainUnchanged() {
        val query = query(ednsCapacity = 1232)
        val policy = DnsUdpResponsePolicy.parseQuery(query, maxUdpPayloadBytes = 1472)
        val small = answer(query, txtBytes = 700)
        val large = answer(query, txtBytes = 1300)

        assertEquals(1232, policy.udpCapacity)
        assertSame(small, DnsUdpResponsePolicy.fitResponse(policy, small))
        assertTruncatedReply(query, DnsUdpResponsePolicy.fitResponse(policy, large))
        assertEquals(512, DnsUdpResponsePolicy.parseQuery(query(ednsCapacity = 32), 1472).udpCapacity)
    }

    @Test
    fun ipv4AndIpv6RepliesFitTheVpnMtuEvenWithLargeEdnsCapacity() {
        val query = query(ednsCapacity = 65_535)
        val answer = answer(query, txtBytes = 1400)
        val clientPort = 43123
        for (ipv6 in listOf(false, true)) {
            val ipHeader = if (ipv6) Packet.IP6_HEADER_SIZE else Packet.IP4_HEADER_SIZE
            val capacity = 1280 - ipHeader - Packet.UDP_HEADER_SIZE
            val policy = DnsUdpResponsePolicy.parseQuery(query, maxUdpPayloadBytes = capacity)
            assertEquals(capacity, policy.udpCapacity)
            val bytes = DnsUdpResponsePolicy.fitResponse(policy, answer)
            assertTruncatedReply(query, bytes)
            val dns = java.net.InetAddress.getByName(if (ipv6) "2606:4700:4700::1111" else "1.1.1.1")
            val client = java.net.InetAddress.getByName(if (ipv6) "fd00:10:10::2" else "10.10.0.2")
            val packet =
                if (ipv6) Packet.buildIp6Udp(dns, client, 53, clientPort, bytes)
                else Packet.buildIp4Udp(dns, client, 53, clientPort, bytes)
            assertTrue(packet.size <= 1280)
            val buffer = ByteBuffer.wrap(packet)
            val udp =
                if (ipv6) Packet.parseUdp(buffer, requireNotNull(Packet.parseIp6(buffer)))
                else Packet.parseUdp(buffer, requireNotNull(Packet.parseIp4(buffer)))
            assertEquals(bytes.size, requireNotNull(udp).payloadLength)
            assertEquals(clientPort, udp.destPort)
        }
    }

    @Test
    fun questionCompressionIsExpandedSoTruncationCannotLeaveDanglingPointers() {
        val original = query()
        val compressed = original + byteArrayOf(0xc0.toByte(), 12, 0, 28, 0, 1)
        compressed[5] = 2
        val policy = DnsUdpResponsePolicy.parseQuery(compressed, 1472)
        val response = ByteArray(700).apply {
            original.copyInto(this)
            this[2] = 0x81.toByte()
        }
        val truncated = DnsUdpResponsePolicy.fitResponse(policy, response)

        val expectedQuestions = original.copyOfRange(12, original.size) +
            original.copyOfRange(12, original.size - 4) + byteArrayOf(0, 28, 0, 1)
        assertEquals(2, truncated[5].toInt())
        assertArrayEquals(expectedQuestions, truncated.copyOfRange(12, truncated.size))
        val reparsed = DnsUdpResponsePolicy.parseQuery(truncated, 1472)
        assertArrayEquals(expectedQuestions, reparsed.questions)
    }

    @Test
    fun malformedNamesAndOutOfBoundsEdnsAreRejectedWithBoundedParsing() {
        val compressionLoop = query().copyOf(18).apply {
            this[12] = 0xc0.toByte()
            this[13] = 12
        }
        val truncatedEdns = query(ednsCapacity = 1232).dropLast(1).toByteArray()
        val invalidLabel = query().apply { this[12] = 0x40 }
        for (invalid in listOf(compressionLoop, truncatedEdns, invalidLabel)) {
            assertThrows(IOException::class.java) { DnsUdpResponsePolicy.parseQuery(invalid, 1472) }
        }
    }

    private fun assertTruncatedReply(query: ByteArray, response: ByteArray) {
        assertEquals(query[0], response[0])
        assertEquals(query[1], response[1])
        assertTrue(response[2].toInt() and 0x80 != 0) // QR
        assertTrue(response[2].toInt() and 0x02 != 0) // TC triggers native DNS/TCP retry
        assertEquals(1, response[5].toInt())
        assertArrayEquals(ByteArray(6), response.copyOfRange(6, 12))
        val questions = DnsUdpResponsePolicy.parseQuery(query, 1472).questions
        assertArrayEquals(questions, response.copyOfRange(12, response.size))
        assertEquals(1, DnsUdpResponsePolicy.parseQuery(response, 1472).questionCount)
    }

    internal companion object {
        fun query(ednsCapacity: Int? = null): ByteArray {
            val base = byteArrayOf(
                0x12, 0x34, 0x01, 0, 0, 1, 0, 0, 0, 0, 0, if (ednsCapacity == null) 0 else 1,
                7, 'e'.code.toByte(), 'x'.code.toByte(), 'a'.code.toByte(), 'm'.code.toByte(), 'p'.code.toByte(), 'l'.code.toByte(), 'e'.code.toByte(),
                4, 't'.code.toByte(), 'e'.code.toByte(), 's'.code.toByte(), 't'.code.toByte(),
                0, 0, 16, 0, 1,
            )
            return if (ednsCapacity == null) base else base + byteArrayOf(
                0, 0, 41, (ednsCapacity ushr 8).toByte(), ednsCapacity.toByte(), 0, 0, 0, 0, 0, 0,
            )
        }

        fun answer(query: ByteArray, txtBytes: Int): ByteArray {
            val questions = DnsUdpResponsePolicy.parseQuery(query, 1472).questions
            val header = query.copyOf(12).apply {
                this[2] = 0x81.toByte()
                this[3] = 0x80.toByte()
                this[7] = 1
                this[11] = 0
            }
            val text = java.io.ByteArrayOutputStream()
            var remaining = txtBytes
            while (remaining > 0) {
                val length = minOf(remaining, 255)
                text.write(length)
                text.write(ByteArray(length) { 'x'.code.toByte() })
                remaining -= length
            }
            val data = text.toByteArray()
            return header + questions + byteArrayOf(
                0xc0.toByte(), 12, 0, 16, 0, 1, 0, 0, 0, 30,
                (data.size ushr 8).toByte(), data.size.toByte(),
            ) + data
        }
    }
}
