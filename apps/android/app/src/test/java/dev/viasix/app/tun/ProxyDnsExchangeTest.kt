package dev.viasix.app.tun

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class ProxyDnsExchangeTest {
    private val query = byteArrayOf(0x12, 0x34, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    private val response = query.copyOf().apply { this[2] = 0x81.toByte() }

    @Test
    fun tcpOnlyProxyAnswersUdpDnsWithoutOpeningUdpAssociation() {
        for (serverAddress in listOf("1.1.1.1", "2606:4700:4700::1111")) {
            val target = InetAddress.getByName(serverAddress)
            withProxy(target) { port, received ->
                val socket = Socket()
                val actual =
                    ProxyDnsExchange.exchangeWithSocket(
                        socket, "127.0.0.1", port, target, query,
                    )
                assertArrayEquals(response, actual)
                assertArrayEquals(query, received.get())
                assertTrue(socket.isClosed)
            }
        }
    }

    @Test
    fun malformedOrUnrelatedRepliesAreRejectedAndSocketClosed() {
        val invalidResponses =
            listOf(
                byteArrayOf(1, 2),
                response.copyOf().apply { this[0] = 0x35 },
                query,
            )
        for (reply in invalidResponses) {
            val target = InetAddress.getByName("1.1.1.1")
            withProxy(target, reply = reply) { port, _ ->
                val socket = Socket()
                assertThrows(IOException::class.java) {
                    ProxyDnsExchange.exchangeWithSocket(
                        socket, "127.0.0.1", port, target, query,
                    )
                }
                assertTrue(socket.isClosed)
            }
        }
    }

    @Test
    fun resolverEofDoesNotReturnAnIncompleteDatagram() {
        val target = InetAddress.getByName("1.1.1.1")
        withProxy(target, reply = null) { port, _ ->
            val socket = Socket()
            assertThrows(EOFException::class.java) {
                ProxyDnsExchange.exchangeWithSocket(
                    socket, "127.0.0.1", port, target, query,
                )
            }
            assertTrue(socket.isClosed)
        }
    }

    @Test
    fun silentResolverTimesOutAfterSocksHandshakeAndReleasesSocket() {
        val target = InetAddress.getByName("1.1.1.1")
        withProxy(target, waitForClientClose = true) { port, _ ->
            val socket = Socket()
            assertThrows(SocketTimeoutException::class.java) {
                ProxyDnsExchange.exchangeWithSocket(
                    socket, "127.0.0.1", port, target, query, timeoutMs = 200,
                )
            }
            assertTrue(socket.isClosed)
        }
    }

    @Test
    fun tunnelStopCancelsAnInFlightProxyDnsQuery() {
        val target = InetAddress.getByName("1.1.1.1")
        val queryReceived = CountDownLatch(1)
        withProxy(target, waitForClientClose = true, queryReceived = queryReceived) { port, _ ->
            val registry = InFlightCloseableRegistry()
            val socket = Socket()
            assertTrue(registry.register(socket))
            val outcome = AtomicReference<Throwable>()
            val worker = thread {
                try {
                    ProxyDnsExchange.exchangeWithSocket(
                        socket, "127.0.0.1", port, target, query,
                    )
                } catch (error: Throwable) {
                    outcome.set(error)
                } finally {
                    registry.unregister(socket)
                }
            }
            try {
                assertTrue(queryReceived.await(2, TimeUnit.SECONDS))
                registry.close()
                worker.join(2_000)
                assertFalse(worker.isAlive)
                assertTrue(outcome.get() is IOException)
                assertTrue(socket.isClosed)
            } finally {
                registry.close()
                worker.join(2_000)
            }
        }
    }

    @Test
    fun largeTcpDnsAnswerBecomesAMatchedTruncatedUdpReply() {
        val request = DnsUdpResponsePolicyTest.query(ednsCapacity = 1232)
        val largeResponse = DnsUdpResponsePolicyTest.answer(request, txtBytes = 1400)
        val target = InetAddress.getByName("1.1.1.1")
        withProxy(target, reply = largeResponse) { port, received ->
            val actual =
                ProxyDnsExchange.exchangeWithSocket(
                    Socket(), "127.0.0.1", port, target, request,
                    maxUdpPayloadBytes = 1232,
                )
            assertArrayEquals(request, received.get())
            assertEquals(request[0], actual[0])
            assertEquals(request[1], actual[1])
            assertTrue(actual[2].toInt() and 0x02 != 0)
            assertEquals(1, actual[5].toInt())
            assertArrayEquals(ByteArray(6), actual.copyOfRange(6, 12))
            assertArrayEquals(request.copyOfRange(12, request.size - 11), actual.copyOfRange(12, actual.size))
        }
    }

    private fun withProxy(
        target: InetAddress,
        reply: ByteArray? = response,
        waitForClientClose: Boolean = false,
        queryReceived: CountDownLatch? = null,
        check: (Int, AtomicReference<ByteArray>) -> Unit,
    ) {
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { listener ->
            listener.soTimeout = 2_000
            val received = AtomicReference<ByteArray>()
            val failure = AtomicReference<Throwable>()
            val proxy = thread {
                try {
                    listener.accept().use { peer ->
                        peer.soTimeout = 2_000
                        val input = DataInputStream(peer.getInputStream())
                        val output = DataOutputStream(peer.getOutputStream())
                        val greeting = ByteArray(3).also(input::readFully)
                        assertArrayEquals(byteArrayOf(5, 1, 0), greeting)
                        output.write(byteArrayOf(5, 0))
                        output.flush()

                        assertEquals(5, input.readUnsignedByte())
                        assertEquals(1, input.readUnsignedByte()) // CONNECT, not UDP ASSOCIATE
                        assertEquals(0, input.readUnsignedByte())
                        assertEquals(if (target.address.size == 4) 1 else 4, input.readUnsignedByte())
                        val destination = ByteArray(target.address.size).also(input::readFully)
                        assertArrayEquals(target.address, destination)
                        assertEquals(53, input.readUnsignedShort())
                        output.write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 53))
                        output.flush()

                        received.set(ByteArray(input.readUnsignedShort()).also(input::readFully))
                        queryReceived?.countDown()
                        if (waitForClientClose) {
                            assertEquals(-1, input.read())
                        } else if (reply != null) {
                            // Deliberately split the length prefix and payload across writes.
                            output.writeByte(reply.size ushr 8)
                            output.flush()
                            output.writeByte(reply.size and 0xff)
                            if (reply.size >= 12) {
                                for (byte in reply) {
                                    output.writeByte(byte.toInt())
                                    output.flush()
                                }
                            }
                        }
                    }
                } catch (error: Throwable) {
                    failure.set(error)
                }
            }
            try {
                check(listener.localPort, received)
            } finally {
                proxy.join(3_000)
                assertFalse("mock proxy must finish", proxy.isAlive)
                failure.get()?.let { throw AssertionError("mock proxy failed", it) }
            }
        }
    }
}
