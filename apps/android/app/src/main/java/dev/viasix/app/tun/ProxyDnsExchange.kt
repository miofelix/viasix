package dev.viasix.app.tun

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.Socket

/** Carries a UDP DNS query over SOCKS/TCP, including proxies without UDP support. */
internal object ProxyDnsExchange {
    fun exchangeWithSocket(
        socket: Socket,
        proxyHost: String,
        proxyPort: Int,
        dnsServer: InetAddress,
        request: ByteArray,
        timeoutMs: Int = 5_000,
        maxUdpPayloadBytes: Int = 65_507,
    ): ByteArray =
        socket.use {
            require(request.size in DNS_HEADER_BYTES..65_535) { "Invalid DNS query length" }
            require(timeoutMs > 0) { "DNS timeout must be positive" }
            val query = DnsUdpResponsePolicy.parseQuery(request, maxUdpPayloadBytes)
            Socks5Client.connectWithSocket(
                socket = socket,
                proxyHost = proxyHost,
                proxyPort = proxyPort,
                targetHost = dnsServer,
                targetPort = 53,
                connectTimeoutMs = timeoutMs,
                handshakeTimeoutMs = timeoutMs,
            )
            // SOCKS clears its handshake timeout once CONNECT succeeds. DNS still
            // needs a bounded response wait so silent resolvers cannot retain workers.
            socket.soTimeout = timeoutMs
            val output = DataOutputStream(socket.getOutputStream())
            output.writeShort(request.size)
            output.write(request)
            output.flush()

            val input = DataInputStream(socket.getInputStream())
            val responseLength = input.readUnsignedShort()
            if (responseLength < DNS_HEADER_BYTES) throw IOException("Truncated DNS response")
            val response = ByteArray(responseLength)
            input.readFully(response)
            if (response[0] != request[0] || response[1] != request[1]) {
                throw IOException("DNS response transaction does not match query")
            }
            if (response[2].toInt() and 0x80 == 0) {
                throw IOException("DNS response is not marked as a response")
            }
            DnsUdpResponsePolicy.fitResponse(query, response)
        }

    private const val DNS_HEADER_BYTES = 12
}
