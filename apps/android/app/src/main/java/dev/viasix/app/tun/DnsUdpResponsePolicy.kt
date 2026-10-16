package dev.viasix.app.tun

import java.io.ByteArrayOutputStream
import java.io.IOException

/** Preserves UDP DNS size negotiation when the upstream exchange uses TCP. */
internal object DnsUdpResponsePolicy {
    internal data class Query(
        val questionCount: Int,
        val questions: ByteArray,
        val udpCapacity: Int,
    )

    fun parseQuery(packet: ByteArray, maxUdpPayloadBytes: Int): Query {
        require(maxUdpPayloadBytes in HEADER_BYTES..65_507) { "Invalid UDP DNS capacity" }
        if (packet.size < HEADER_BYTES) throw IOException("Truncated DNS query")
        val questionCount = unsignedShort(packet, 4)
        val questions = ByteArrayOutputStream()
        var offset = HEADER_BYTES
        repeat(questionCount) {
            val name = readName(packet, offset)
            offset = name.nextOffset
            requireBytes(packet, offset, 4)
            if (HEADER_BYTES + questions.size() + name.expanded.size + 4 > maxUdpPayloadBytes) {
                throw IOException("DNS questions exceed UDP response capacity")
            }
            questions.write(name.expanded)
            questions.write(packet, offset, 4)
            offset += 4
        }

        var advertisedCapacity = 512
        for (section in 0..2) {
            val count = unsignedShort(packet, 6 + section * 2)
            repeat(count) {
                offset = readName(packet, offset).nextOffset
                requireBytes(packet, offset, 10)
                val type = unsignedShort(packet, offset)
                val recordClass = unsignedShort(packet, offset + 2)
                val dataLength = unsignedShort(packet, offset + 8)
                offset += 10
                requireBytes(packet, offset, dataLength)
                if (section == 2 && type == 41) {
                    // RFC 6891: advertised values below 512 are treated as 512.
                    advertisedCapacity = recordClass.coerceAtLeast(512)
                }
                offset += dataLength
            }
        }
        return Query(questionCount, questions.toByteArray(), minOf(advertisedCapacity, maxUdpPayloadBytes))
    }

    fun fitResponse(query: Query, response: ByteArray): ByteArray {
        if (response.size <= query.udpCapacity) return response
        // Retain a complete question section so the client can match this reply
        // and retry its original query over TCP. Expanded names cannot refer to
        // records that are omitted from this deliberately truncated response.
        if (HEADER_BYTES + query.questions.size > query.udpCapacity) {
            throw IOException("DNS questions exceed advertised UDP capacity")
        }
        return ByteArray(HEADER_BYTES + query.questions.size).also { truncated ->
            response.copyInto(truncated, endIndex = HEADER_BYTES)
            truncated[2] = (truncated[2].toInt() or 0x02).toByte() // TC
            truncated[4] = (query.questionCount ushr 8).toByte()
            truncated[5] = query.questionCount.toByte()
            truncated.fill(0, fromIndex = 6, toIndex = HEADER_BYTES)
            query.questions.copyInto(truncated, destinationOffset = HEADER_BYTES)
        }
    }

    private data class Name(val nextOffset: Int, val expanded: ByteArray)

    private fun readName(packet: ByteArray, start: Int): Name {
        var offset = start
        var nextOffset = -1
        var jumps = 0
        val expanded = ByteArrayOutputStream()
        while (true) {
            requireBytes(packet, offset, 1)
            val length = packet[offset].toInt() and 0xff
            if (length and 0xc0 == 0xc0) {
                requireBytes(packet, offset, 2)
                if (nextOffset < 0) nextOffset = offset + 2
                if (++jumps > 128) throw IOException("DNS name compression loop")
                offset = ((length and 0x3f) shl 8) or (packet[offset + 1].toInt() and 0xff)
                continue
            }
            if (length and 0xc0 != 0) throw IOException("Invalid DNS name label")
            requireBytes(packet, offset + 1, length)
            if (expanded.size() + length + 1 > 255) throw IOException("DNS name is too long")
            expanded.write(length)
            expanded.write(packet, offset + 1, length)
            offset += length + 1
            if (length == 0) return Name(if (nextOffset < 0) offset else nextOffset, expanded.toByteArray())
        }
    }

    private fun unsignedShort(packet: ByteArray, offset: Int): Int =
        ((packet[offset].toInt() and 0xff) shl 8) or (packet[offset + 1].toInt() and 0xff)

    private fun requireBytes(packet: ByteArray, offset: Int, count: Int) {
        if (offset < 0 || count < 0 || offset > packet.size - count) throw IOException("Truncated DNS query")
    }

    private const val HEADER_BYTES = 12
}
