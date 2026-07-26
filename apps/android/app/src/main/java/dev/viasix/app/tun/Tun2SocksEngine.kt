package dev.viasix.app.tun

import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import dev.viasix.app.session.DnsRoutingMode
import dev.viasix.app.session.DnsSettingsPolicy
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.random.Random

/**
 * Userspace IPv4/IPv6 forwarder for full-tunnel mode:
 * - TCP → SOCKS5 CONNECT (mihomo mixed port), except explicit protected-direct DNS/TCP
 * - UDP general → SOCKS5 UDP ASSOCIATE **per local client endpoint** (correct demux)
 * - TCP/UDP port 53 → SOCKS5 by default, or protected direct sockets when requested
 *
 * ASSOCIATE open runs on the worker pool (never blocks the TUN reader). Failures are
 * negative-cached so retries do not stall packet processing.
 */
class Tun2SocksEngine(
    private val vpnService: VpnService,
    private val tun: ParcelFileDescriptor,
    private val socksHost: String,
    private val socksPort: Int,
    private val dnsRoutingMode: DnsRoutingMode = DnsRoutingMode.PROXY,
    private val dnsUpstream: InetAddress = InetAddress.getByName("1.1.1.1"),
    private val mtu: Int = 1_500,
    private val maxSessions: Int = 256,
    private val maxUdpClients: Int = 256,
    maxDirectDnsQueries: Int = 32,
    maxConnectionWorkers: Int = 16,
    // Downstream readers hold one io thread per live TCP session, so the pool
    // must cover maxSessions (admission control) plus transient upstream
    // writers; a smaller pool RSTs healthy sessions mid-connection.
    maxIoWorkers: Int = maxSessions + 64,
    private val associateFailBackoffMs: Long = 5_000L,
) {
    private val running = AtomicBoolean(false)

    val isRunning: Boolean
        get() = running.get()

    private val sessions = ConcurrentHashMap<String, TcpSession>()
    private val activeSessionCount = AtomicInteger(0)
    private val udpClients = UdpClientEndpointTable(maxEntries = maxUdpClients)
    private val udpRelays = ConcurrentHashMap<String, UdpClientRelay>()
    private val directDnsGate = BoundedConcurrencyGate(maxDirectDnsQueries)
    private val inFlightIo = InFlightCloseableRegistry()
    private var readerThread: Thread? = null
    private var writerThread: Thread? = null
    private val outboundPackets = OutboundPacketQueue(capacity = 512)
    private val connectionWorkers =
        BoundedWorkerPool(maxConnectionWorkers, "viasix-tun-connect")
    private val ioWorkers = BoundedWorkerPool(maxIoWorkers, "viasix-tun-io")
    private val maintenanceExecutor =
        Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "viasix-tun-maintenance").apply { isDaemon = true }
        }
    private val udpRelayReactor =
        UdpRelayReactor(
            onFatal = { error ->
                if (running.compareAndSet(true, false)) {
                    Log.w(TAG, "UDP relay reactor failed: ${error.message}")
                }
            },
        )
    private var inChannel: FileChannel? = null
    private var outStream: FileOutputStream? = null
    private var started = false
    private var stopped = false

    init {
        TcpSegmentSizer.maxPayloadBytes(mtu, ipv6 = true)
    }

    @Synchronized
    fun start() {
        check(!stopped) { "Tun2SocksEngine cannot restart after stop" }
        if (started) return
        started = true
        if (!running.compareAndSet(false, true)) return
        try {
            val input = FileInputStream(tun.fileDescriptor).channel
            inChannel = input
            val output = FileOutputStream(tun.fileDescriptor)
            outStream = output
            udpRelayReactor.start()
            maintenanceExecutor.scheduleWithFixedDelay(
                {
                    try {
                        retransmitDueTcpSegments()
                    } catch (error: Exception) {
                        Log.w(TAG, "TCP retransmission scan failed: ${error.message}")
                    }
                },
                RETRANSMISSION_SCAN_MS,
                RETRANSMISSION_SCAN_MS,
                TimeUnit.MILLISECONDS,
            )
            maintenanceExecutor.scheduleWithFixedDelay(
                {
                    try {
                        purgeIdleUdpClients()
                    } catch (error: Exception) {
                        Log.w(TAG, "UDP idle cleanup failed: ${error.message}")
                    }
                },
                UDP_IDLE_CLEANUP_INTERVAL_MS,
                UDP_IDLE_CLEANUP_INTERVAL_MS,
                TimeUnit.MILLISECONDS,
            )

            writerThread =
                Thread(
                    {
                        try {
                            while (running.get()) {
                                val packet =
                                    outboundPackets.poll(timeoutMs = 200L) ?: continue
                                output.write(packet)
                                output.flush()
                            }
                        } catch (error: Exception) {
                            if (running.get()) {
                                Log.w(TAG, "tun write failed: ${error.message}")
                            }
                        } finally {
                            running.set(false)
                        }
                    },
                    "viasix-tun-writer",
                ).also {
                    it.isDaemon = true
                    it.start()
                }

            readerThread =
                Thread(
                    {
                        val buffer = ByteBuffer.allocate(32767)
                        try {
                            while (running.get()) {
                                buffer.clear()
                                val len =
                                    try {
                                        input.read(buffer)
                                    } catch (_: Exception) {
                                        break
                                    }
                                if (len <= 0) continue
                                buffer.flip()
                                try {
                                    handlePacket(buffer)
                                } catch (error: Exception) {
                                    Log.w(TAG, "drop malformed TUN packet: ${error.message}")
                                }
                            }
                        } finally {
                            running.set(false)
                        }
                    },
                    "viasix-tun-reader",
                ).also {
                    it.isDaemon = true
                    it.start()
                }
            Log.i(TAG, "Tun2SocksEngine started socks=$socksHost:$socksPort (TCP+UDP IPv4/IPv6)")
        } catch (error: Throwable) {
            stop()
            throw error
        }
    }

    @Synchronized
    fun stop() {
        if (stopped) return
        stopped = true
        running.set(false)
        val reader = readerThread
        val writer = writerThread
        try {
            reader?.interrupt()
        } catch (_: Exception) {
        }
        try {
            writer?.interrupt()
        } catch (_: Exception) {
        }
        maintenanceExecutor.shutdownNow()
        inFlightIo.close()
        sessions.values.forEach { it.close() }
        sessions.clear()
        activeSessionCount.set(0)
        closeAllUdpRelays()
        udpRelayReactor.close()
        udpClients.clear()
        outboundPackets.cancel()
        try {
            inChannel?.close()
        } catch (_: Exception) {
        }
        inChannel = null
        try {
            outStream?.close()
        } catch (_: Exception) {
        }
        outStream = null
        connectionWorkers.close()
        ioWorkers.close()
        joinTunThread(reader, "reader")
        joinTunThread(writer, "writer")
        awaitMaintenanceTermination()
        readerThread = null
        writerThread = null
        Log.i(TAG, "Tun2SocksEngine stopped")
    }

    private fun joinTunThread(thread: Thread?, label: String) {
        if (thread == null || thread === Thread.currentThread()) return
        try {
            thread.join(STOP_TIMEOUT_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        if (thread.isAlive) Log.w(TAG, "TUN $label thread did not stop within timeout")
    }

    private fun awaitMaintenanceTermination() {
        try {
            if (!maintenanceExecutor.awaitTermination(STOP_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                Log.w(TAG, "TUN maintenance executor did not stop within timeout")
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun handlePacket(buffer: ByteBuffer) {
        when (Packet.ipVersion(buffer)) {
            4 -> {
                val ip = Packet.parseIp4(buffer) ?: return
                when (ip.protocol) {
                    Packet.PROTO_TCP.toInt() -> handleTcp4(buffer, ip)
                    Packet.PROTO_UDP.toInt() -> handleUdp4(buffer, ip)
                }
            }
            6 -> {
                val ip = Packet.parseIp6(buffer) ?: return
                when (ip.nextHeader) {
                    Packet.PROTO_TCP.toInt() -> handleTcp6(buffer, ip)
                    Packet.PROTO_UDP.toInt() -> handleUdp6(buffer, ip)
                }
            }
        }
    }

    // region IPv4/IPv6 TCP

    private fun handleTcp4(buffer: ByteBuffer, ip: Packet.Ip4) {
        val tcp = Packet.parseTcp(buffer, ip) ?: return
        handleTcpCommon(
            buffer = buffer,
            tcp = tcp,
            clientIp = ip.source,
            remoteIp = ip.destination,
            ipv6 = false,
        )
    }

    private fun handleTcp6(buffer: ByteBuffer, ip: Packet.Ip6) {
        val tcp = Packet.parseTcp(buffer, ip) ?: return
        handleTcpCommon(
            buffer = buffer,
            tcp = tcp,
            clientIp = ip.source,
            remoteIp = ip.destination,
            ipv6 = true,
        )
    }

    private fun handleTcpCommon(
        buffer: ByteBuffer,
        tcp: Packet.Tcp,
        clientIp: InetAddress,
        remoteIp: InetAddress,
        ipv6: Boolean,
    ) {
        val key = key(clientIp, tcp.sourcePort, remoteIp, tcp.destPort)

        if (
            tcp.flags and Packet.SYN != 0 &&
                tcp.flags and (Packet.ACK or Packet.RST or Packet.FIN) == 0
        ) {
            val existing = sessions[key]
            if (existing != null) {
                if (!existing.handshake.isComplete && existing.socket != null) {
                    enqueueSynAck(existing)
                } else if (existing.handshake.isComplete) {
                    enqueueChallengeAck(existing)
                }
                return
            }
            if (activeSessionCount.get() >= maxSessions) {
                Log.w(TAG, "session limit $maxSessions reached; reset SYN")
                enqueueClosedStateReset(tcp, clientIp, remoteIp, ipv6)
                return
            }
            val session =
                TcpSession(
                    clientIp = clientIp,
                    clientPort = tcp.sourcePort,
                    remoteIp = remoteIp,
                    remotePort = tcp.destPort,
                    clientIsn = tcp.seq,
                    clientMaximumSegmentSize = tcp.maximumSegmentSize,
                    clientWindowScale = tcp.windowScale,
                    ipv6 = ipv6,
                )
            sessions[key] = session
            activeSessionCount.incrementAndGet()
            if (!connectionWorkers.execute { openTcpSession(key, session) }) {
                Log.w(TAG, "TCP connection worker limit reached; reject $key")
                rejectTcpSession(key, session)
            }
            return
        }

        val session = sessions[key]
        if (session == null) {
            enqueueClosedStateReset(tcp, clientIp, remoteIp, ipv6)
            return
        }
        val receiveWindow = session.upstream.advertisedWindow()

        if (tcp.flags and Packet.RST != 0) {
            if (session.socket == null) return
            when (
                TcpResetPolicy.classify(
                    sequence = tcp.seq,
                    nextExpected = session.clientNextSeq,
                    receiveWindow = receiveWindow,
                )
            ) {
                TcpResetPolicy.Action.CLOSE -> removeSession(key, session)
                TcpResetPolicy.Action.CHALLENGE_ACK -> {
                    if (session.handshake.isComplete) enqueueChallengeAck(session)
                }
                TcpResetPolicy.Action.DROP -> Unit
            }
            return
        }

        if (tcp.flags and Packet.SYN != 0) {
            if (!session.handshake.isComplete && session.socket != null) {
                enqueueSynAck(session)
            } else if (session.handshake.isComplete) {
                enqueueChallengeAck(session)
            }
            return
        }

        if (!session.handshake.isComplete && tcp.flags and Packet.ACK != 0) {
            if (
                session.socket != null &&
                    session.handshake.acknowledge(
                        sequence = tcp.seq,
                        expectedSequence = session.clientNextSeq,
                        acknowledgement = tcp.ack,
                        expectedAcknowledgement = session.serverSeq,
                        flags = tcp.flags,
                    ) &&
                    !ensureTcpDownstreamReader(key, session)
            ) {
                Log.w(TAG, "TCP downstream reader limit reached for $key")
                rejectTcpSession(key, session)
                return
            }
        }
        if (
            session.handshake.isComplete &&
                (
                    tcp.flags and Packet.ACK == 0 ||
                        !TcpReceiveWindow.accepts(
                            sequence = tcp.seq,
                            payloadLength = tcp.payloadLength,
                            fin = tcp.flags and Packet.FIN != 0,
                            nextExpected = session.clientNextSeq,
                            receiveWindow = receiveWindow,
                        )
                )
        ) {
            enqueueAck(session)
            return
        }
        if (session.handshake.isComplete && tcp.flags and Packet.ACK != 0) {
            val advertisedWindow =
                TcpWindowScale.expand(
                    advertisedWindow = tcp.window,
                    shift = session.clientWindowScale ?: 0,
                )
            if (
                session.sendWindow.update(
                    segmentSequence = tcp.seq,
                    acknowledgement = tcp.ack,
                    advertisedWindow = advertisedWindow,
                    nextSequence = session.serverSeq,
                )
            ) {
                val nowMs = monotonicTimeMs()
                val acknowledgementAdvanced =
                    session.retransmissions.acknowledge(
                        acknowledgement = tcp.ack,
                        nowMs = nowMs,
                        advertisedWindow = advertisedWindow,
                    )
                if (
                    !acknowledgementAdvanced &&
                        tcp.payloadLength == 0 &&
                        tcp.flags and (Packet.SYN or Packet.FIN or Packet.RST) == 0
                ) {
                    session.retransmissions.noteDuplicateAcknowledgement(
                        acknowledgement = tcp.ack,
                        nowMs = nowMs,
                        advertisedWindow = advertisedWindow,
                    )?.let { due ->
                        enqueueTcpRetransmission(key, session, due, reason = "fast")
                    }
                }
                if (
                    session.closeState.acknowledgeServerFin(tcp.ack) &&
                        session.closeState.isFullyClosed
                ) {
                    removeSession(key, session)
                    return
                }
            }
        }

        if (tcp.payloadLength > 0 && session.closeState.hasClientFin) {
            enqueueAck(session)
            return
        }
        if (tcp.payloadLength > 0 && session.handshake.isComplete && session.socket != null) {
            val skip =
                TcpSequence.consumedPayloadPrefix(
                    segmentStart = tcp.seq,
                    payloadLength = tcp.payloadLength,
                    nextExpected = session.clientNextSeq,
                )
            if (skip == null) {
                enqueueAck(session)
                return
            }
            if (skip >= tcp.payloadLength) {
                enqueueAck(session)
                if (tcp.flags and Packet.FIN == 0) return
            } else {
                val payload = ByteArray(tcp.payloadLength - skip)
                val pos = buffer.position()
                buffer.position(tcp.payloadOffset + skip)
                buffer.get(payload)
                buffer.position(pos)
                if (!session.upstream.offer(payload)) {
                    enqueueAck(session)
                    return
                }
                session.clientNextSeq =
                    TcpSequence.advance(tcp.seq, payloadLength = tcp.payloadLength)
                if (!ensureTcpUpstreamWriter(key, session)) {
                    Log.w(TAG, "TCP upstream writer limit reached for $key")
                    rejectTcpSession(key, session)
                    return
                }
                enqueueAck(session)
            }
        }

        if (tcp.flags and Packet.FIN != 0 && session.handshake.isComplete) {
            val finSequence = TcpSequence.advance(tcp.seq, payloadLength = tcp.payloadLength)
            if (finSequence == session.clientNextSeq && session.closeState.markClientFin()) {
                session.clientNextSeq = TcpSequence.advance(finSequence, fin = true)
                if (!ensureTcpUpstreamWriter(key, session)) {
                    Log.w(TAG, "TCP FIN writer limit reached for $key")
                    rejectTcpSession(key, session)
                    return
                }
                enqueueAck(session)
                if (session.closeState.isFullyClosed) removeSession(key, session)
            } else {
                enqueueAck(session)
            }
        }
    }

    private fun openTcpSession(key: String, session: TcpSession) {
        val useProtectedDirect =
            DnsSettingsPolicy.shouldUseProtectedDirect(
                destinationPort = session.remotePort,
                mode = dnsRoutingMode,
            )
        val outboundHost = if (useProtectedDirect) dnsUpstream else session.remoteIp
        val connectingSocket = Socket()
        if (!inFlightIo.register(connectingSocket)) {
            removeSession(key, session)
            return
        }
        try {
            val socket =
                if (useProtectedDirect) {
                    ProtectedSocketConnector.connectWithSocket(
                        socket = connectingSocket,
                        targetHost = dnsUpstream,
                        targetPort = session.remotePort,
                        protect = { socket -> vpnService.protect(socket) },
                    )
                } else {
                    Socks5Client.connectWithSocket(
                        socket = connectingSocket,
                        proxyHost = socksHost,
                        proxyPort = socksPort,
                        targetHost = session.remoteIp,
                        targetPort = session.remotePort,
                    )
                }
            if (!running.get()) {
                socket.close()
                removeSession(key, session)
                return
            }
            session.serverIsn = Random.nextInt().toLong() and 0xffffffffL
            session.serverSeq = TcpSequence.advance(session.serverIsn, syn = true)
            session.clientNextSeq = TcpSequence.advance(session.clientIsn, syn = true)
            session.socket = socket
            inFlightIo.unregister(socket)

            val synAckQueued = retainAndEnqueueSynAck(session)
            if (!synAckQueued) {
                removeSession(key, session)
                return
            }
            session.handshakeDeadlineMs = monotonicTimeMs() + HANDSHAKE_TIMEOUT_MS
        } catch (error: Exception) {
            val route = if (useProtectedDirect) "protected direct" else "SOCKS"
            if (running.get()) {
                Log.w(
                    TAG,
                    "$route connect ${outboundHost.hostAddress}:${session.remotePort}: ${error.message}",
                )
                enqueuePacket(
                    buildTcpPacket(
                        session = session,
                        seq = 0,
                        ack = TcpSequence.advance(session.clientIsn, syn = true),
                        flags = Packet.RST or Packet.ACK,
                        payload = ByteArray(0),
                    ),
                    lossless = true,
                )
            }
            removeSession(key, session)
        } finally {
            inFlightIo.unregister(connectingSocket)
        }
    }

    private fun ensureTcpDownstreamReader(key: String, session: TcpSession): Boolean {
        val socket = session.socket ?: return false
        if (!session.downstreamReaderStarted.compareAndSet(false, true)) return true
        if (ioWorkers.execute { readTcpDownstream(key, session, socket) }) return true
        session.downstreamReaderStarted.set(false)
        return false
    }

    private fun readTcpDownstream(key: String, session: TcpSession, socket: Socket) {
        val buf =
            ByteArray(
                TcpSegmentSizer.negotiatedPayloadBytes(
                    mtu = mtu,
                    ipv6 = session.ipv6,
                    peerMss = session.clientMaximumSegmentSize,
                ),
            )
        var remoteEof = false
        try {
            val input = socket.getInputStream()
            while (running.get() && sessions[key] === session && !socket.isClosed) {
                val allowance =
                    session.sendWindow.awaitAllowance(
                        maxBytes = buf.size,
                        timeoutMs = WINDOW_WAIT_POLL_MS,
                    )
                if (allowance <= 0) continue
                val n = input.read(buf, 0, allowance)
                if (n < 0) {
                    remoteEof = true
                    break
                }
                if (n == 0) continue
                val chunk = buf.copyOf(n)
                val sequence = session.serverSeq
                val packet =
                    buildTcpPacket(
                        session = session,
                        seq = sequence,
                        ack = session.clientNextSeq,
                        flags = Packet.PSH or Packet.ACK,
                        payload = chunk,
                    )
                val reservation =
                    session.retransmissions.reserve(
                        sequence = sequence,
                        flags = Packet.PSH or Packet.ACK,
                        payload = chunk,
                    )
                if (reservation == null) {
                    session.retransmissions.cancel()
                    break
                }
                if (!session.sendWindow.recordSent(sequence, sequenceLength = n)) {
                    session.retransmissions.discard(reservation)
                    session.retransmissions.cancel()
                    break
                }
                session.serverSeq = TcpSequence.advance(sequence, payloadLength = n)
                val queued = enqueuePacket(packet, lossless = true)
                if (!queued) {
                    session.retransmissions.cancel()
                    break
                }
                session.retransmissions.markQueued(reservation, monotonicTimeMs())
            }
        } catch (error: Exception) {
            if (running.get() && sessions[key] === session) {
                Log.w(TAG, "tcp downstream read failed: ${error.message}")
            }
        } finally {
            val current = running.get() && sessions[key] === session
            if (!remoteEof) {
                if (current) {
                    rejectTcpSession(key, session)
                } else {
                    removeSession(key, session)
                }
            } else {
                val drained =
                    current &&
                        session.retransmissions.awaitEmpty(RETRANSMISSION_DRAIN_TIMEOUT_MS)
                val finAllowed =
                    drained &&
                        session.sendWindow.awaitAllowance(
                            maxBytes = 1,
                            timeoutMs = SERVER_FIN_WINDOW_TIMEOUT_MS,
                        ) > 0
                val finRetained =
                    finAllowed &&
                        running.get() &&
                        sessions[key] === session &&
                        enqueueServerFin(session)
                if (!finRetained) removeSession(key, session)
            }
        }
    }

    private fun rejectTcpSession(key: String, session: TcpSession) {
        if (sessions[key] !== session) return
        val established = session.socket != null
        enqueuePacket(
            buildTcpPacket(
                session = session,
                seq =
                    if (established) {
                        session.sendWindow.acknowledgedSequence() ?: session.serverSeq
                    } else {
                        0
                    },
                ack =
                    if (established) {
                        session.clientNextSeq
                    } else {
                        TcpSequence.advance(session.clientIsn, syn = true)
                    },
                flags = Packet.RST or Packet.ACK,
                payload = ByteArray(0),
            ),
            lossless = true,
        )
        removeSession(key, session)
    }

    private fun enqueueClosedStateReset(
        tcp: Packet.Tcp,
        clientIp: InetAddress,
        remoteIp: InetAddress,
        ipv6: Boolean,
    ): Boolean {
        val reset = TcpClosedStateReset.forSegment(tcp) ?: return false
        val packet =
            if (ipv6) {
                Packet.buildIp6Tcp(
                    source = remoteIp,
                    destination = clientIp,
                    sourcePort = tcp.destPort,
                    destPort = tcp.sourcePort,
                    seq = reset.sequence,
                    ack = reset.acknowledgement,
                    flags = reset.flags,
                    payload = ByteArray(0),
                )
            } else {
                Packet.buildIp4Tcp(
                    source = remoteIp,
                    destination = clientIp,
                    sourcePort = tcp.destPort,
                    destPort = tcp.sourcePort,
                    seq = reset.sequence,
                    ack = reset.acknowledgement,
                    flags = reset.flags,
                    payload = ByteArray(0),
                )
            }
        return enqueuePacket(packet, lossless = true)
    }

    private fun buildTcpPacket(
        session: TcpSession,
        seq: Long,
        ack: Long,
        flags: Int,
        payload: ByteArray,
        maximumSegmentSize: Int? = null,
        windowScale: Int? = null,
    ): ByteArray =
        if (session.ipv6) {
            Packet.buildIp6Tcp(
                source = session.remoteIp,
                destination = session.clientIp,
                sourcePort = session.remotePort,
                destPort = session.clientPort,
                seq = seq,
                ack = ack,
                flags = flags,
                payload = payload,
                maximumSegmentSize = maximumSegmentSize,
                windowScale = windowScale,
                window = session.upstream.advertisedWindow(),
            )
        } else {
            Packet.buildIp4Tcp(
                source = session.remoteIp,
                destination = session.clientIp,
                sourcePort = session.remotePort,
                destPort = session.clientPort,
                seq = seq,
                ack = ack,
                flags = flags,
                payload = payload,
                maximumSegmentSize = maximumSegmentSize,
                windowScale = windowScale,
                window = session.upstream.advertisedWindow(),
            )
        }

    private fun enqueueSynAck(session: TcpSession): Boolean =
        enqueuePacket(
            buildTcpPacket(
                session = session,
                seq = session.serverIsn,
                ack = session.clientNextSeq,
                flags = Packet.SYN or Packet.ACK,
                payload = ByteArray(0),
                maximumSegmentSize = TcpSegmentSizer.maxPayloadBytes(mtu, session.ipv6),
                windowScale =
                    if (session.clientWindowScale != null) SERVER_WINDOW_SCALE else null,
            ),
            lossless = true,
        )

    private fun retainAndEnqueueSynAck(session: TcpSession): Boolean {
        val reservation =
            session.retransmissions.reserve(
                sequence = session.serverIsn,
                flags = Packet.SYN or Packet.ACK,
                payload = ByteArray(0),
            ) ?: return false
        if (!enqueueSynAck(session)) {
            session.retransmissions.discard(reservation)
            return false
        }
        session.retransmissions.markQueued(reservation, monotonicTimeMs())
        return true
    }

    private fun ensureTcpUpstreamWriter(key: String, session: TcpSession): Boolean {
        val socket = session.socket ?: return false
        if (!session.upstreamWriterActive.compareAndSet(false, true)) return true
        if (ioWorkers.execute { writeTcpUpstream(key, session, socket) }) return true
        session.upstreamWriterActive.set(false)
        return false
    }

    private fun writeTcpUpstream(
        key: String,
        session: TcpSession,
        socket: Socket,
    ) {
        var idleSinceMs = monotonicTimeMs()
        try {
            val output = socket.getOutputStream()
            while (running.get() && sessions[key] === session && !socket.isClosed) {
                val payload = session.upstream.poll(UPSTREAM_POLL_MS)
                if (payload != null) {
                    output.write(payload)
                    output.flush()
                    if (session.upstream.complete(payload.size)) {
                        session.windowUpdatePending.set(true)
                    }
                    idleSinceMs = monotonicTimeMs()
                    continue
                }
                if (
                    session.closeState.hasClientFin &&
                        session.outputShutdown.compareAndSet(false, true)
                ) {
                    socket.shutdownOutput()
                    return
                }
                if (monotonicTimeMs() - idleSinceMs >= UPSTREAM_WRITER_IDLE_MS) return
            }
        } catch (error: Exception) {
            if (running.get() && sessions[key] === session) {
                Log.w(TAG, "tcp upstream write failed: ${error.message}")
                removeSession(key, session)
            }
        } finally {
            session.upstreamWriterActive.set(false)
            val needsRestart =
                running.get() &&
                    sessions[key] === session &&
                    !socket.isClosed &&
                    (
                        session.upstream.hasPending ||
                            (session.closeState.hasClientFin && !session.outputShutdown.get())
                    )
            if (needsRestart && !ensureTcpUpstreamWriter(key, session)) {
                Log.w(TAG, "TCP upstream writer restart limit reached for $key")
                rejectTcpSession(key, session)
            }
        }
    }

    private fun enqueueServerFin(session: TcpSession): Boolean {
        val sequence = session.serverSeq
        val sequenceEnd = TcpSequence.advance(sequence, fin = true)
        val flags = Packet.FIN or Packet.ACK
        val payload = ByteArray(0)
        val packet =
            buildTcpPacket(
                session = session,
                seq = sequence,
                ack = session.clientNextSeq,
                flags = flags,
                payload = payload,
            )
        val reservation =
            session.retransmissions.reserve(
                sequence = sequence,
                flags = flags,
                payload = payload,
            ) ?: return false
        val nowMs = monotonicTimeMs()
        if (!session.closeState.markServerFin(sequenceEnd, nowMs)) {
            session.retransmissions.discard(reservation)
            return false
        }
        if (!session.sendWindow.recordSent(sequence, sequenceLength = 1)) {
            session.retransmissions.cancel()
            return false
        }
        session.serverSeq = sequenceEnd
        if (!enqueuePacket(packet, lossless = true)) {
            session.retransmissions.cancel()
            return false
        }
        session.retransmissions.markQueued(reservation, monotonicTimeMs())
        return true
    }

    // endregion

    // region UDP

    private fun handleUdp4(buffer: ByteBuffer, ip: Packet.Ip4) {
        val udp = Packet.parseUdp(buffer, ip) ?: return
        forwardUdp(
            buffer = buffer,
            udp = udp,
            clientIp = ip.source,
            remoteIp = ip.destination,
            ipv6 = false,
        )
    }

    private fun handleUdp6(buffer: ByteBuffer, ip: Packet.Ip6) {
        val udp = Packet.parseUdp(buffer, ip) ?: return
        forwardUdp(
            buffer = buffer,
            udp = udp,
            clientIp = ip.source,
            remoteIp = ip.destination,
            ipv6 = true,
        )
    }

    private fun forwardUdp(
        buffer: ByteBuffer,
        udp: Packet.Udp,
        clientIp: InetAddress,
        remoteIp: InetAddress,
        ipv6: Boolean,
    ) {
        if (udp.payloadLength < 0) return
        val payload = ByteArray(udp.payloadLength.coerceAtLeast(0))
        if (payload.isNotEmpty()) {
            val pos = buffer.position()
            buffer.position(udp.payloadOffset)
            buffer.get(payload)
            buffer.position(pos)
        }

        // Explicit direct DNS keeps per-query protected sockets for concurrent demux.
        // Proxy DNS falls through to the per-client SOCKS5 UDP ASSOCIATE path below.
        if (DnsSettingsPolicy.shouldUseProtectedDirect(udp.destPort, dnsRoutingMode)) {
            val permit = directDnsGate.tryAcquire()
            if (permit == null) {
                Log.w(TAG, "direct DNS query limit reached; drop")
                return
            }
            if (!ioWorkers.execute {
                try {
                    forwardDnsDirect(clientIp, udp.sourcePort, remoteIp, payload, ipv6)
                } finally {
                    permit.close()
                }
            }) {
                permit.close()
                Log.w(TAG, "direct DNS worker limit reached; drop")
            }
            return
        }

        // Drop idle client associates opportunistically (non-blocking).
        udpClients.purgeExpired(::closeExpiredUdpRelay)

        val endpoint =
            UdpClientEndpointTable.Endpoint(
                ip = clientIp,
                port = udp.sourcePort,
                ipv6 = ipv6,
            )
        if (!udpClients.noteActivity(endpoint)) {
            Log.w(TAG, "UDP client limit $maxUdpClients reached; drop")
            return
        }

        forwardUdpViaSocks(endpoint, remoteIp, udp.destPort, payload)
    }

    private fun forwardUdpViaSocks(
        endpoint: UdpClientEndpointTable.Endpoint,
        remoteIp: InetAddress,
        remotePort: Int,
        payload: ByteArray,
    ) {
        if (!running.get()) return
        val clientKey = endpoint.key()
        for (attempt in 0 until UDP_RELAY_OPERATION_ATTEMPTS) {
            val clientRelay =
                udpRelays.compute(clientKey) { _, existing ->
                    if (existing == null || existing.isClosed) {
                        UdpClientRelay(endpoint)
                    } else {
                        existing
                    }
                } ?: return
            if (!running.get()) {
                closeUdpRelay(clientRelay)
                return
            }

            val relay = clientRelay.currentRelay()
            if (relay != null) {
                if (relay.isOpen) {
                    try {
                        when (udpRelayReactor.send(relay, remoteIp, remotePort, payload)) {
                            UdpRelayReactor.SendResult.QUEUED -> return
                            UdpRelayReactor.SendResult.QUEUE_FULL -> {
                                Log.w(TAG, "UDP relay send queue full; drop")
                                return
                            }
                            UdpRelayReactor.SendResult.UNAVAILABLE -> Unit
                        }
                    } catch (error: Exception) {
                        Log.w(TAG, "UDP via SOCKS failed: ${error.message}")
                    }
                }
                // A published relay is single-use. Retire its generation before reopening.
                closeUdpRelay(clientRelay)
                continue
            }

            // Negative cache: do not retry ASSOCIATE on every packet after a recent failure.
            if (monotonicTimeMs() < clientRelay.failedUntilMs.get()) return

            // Queue a small amount of early datagrams while ASSOCIATE opens off the reader thread.
            if (!clientRelay.offerPending(remoteIp, remotePort, payload)) {
                closeUdpRelay(clientRelay)
                continue
            }
            if (clientRelay.tryStartOpening()) {
                if (!connectionWorkers.execute { openUdpAssociate(clientRelay) }) {
                    if (running.get()) {
                        clientRelay.failedUntilMs.set(monotonicTimeMs() + associateFailBackoffMs)
                        clientRelay.clearPending()
                    } else {
                        closeUdpRelay(clientRelay)
                    }
                    clientRelay.finishOpening()
                    Log.w(TAG, "UDP ASSOCIATE worker limit reached; backoff")
                }
            }
            return
        }
        Log.w(TAG, "UDP relay lifecycle contention for $clientKey; drop")
    }

    private fun openUdpAssociate(clientRelay: UdpClientRelay) {
        if (!running.get()) {
            closeUdpRelay(clientRelay)
            clientRelay.finishOpening()
            return
        }
        var installed = false
        val controlSocket = Socket()
        if (!inFlightIo.register(controlSocket)) {
            closeUdpRelay(clientRelay)
            clientRelay.finishOpening()
            return
        }
        try {
            val relay =
                Socks5UdpRelay.openWithControlSocket(
                    control = controlSocket,
                    proxyHost = socksHost,
                    proxyPort = socksPort,
                    protect = { socket: Socket -> vpnService.protect(socket) },
                    protectDatagram = { ds: DatagramSocket -> vpnService.protect(ds) },
                )
            if (!running.get() || udpRelays[clientRelay.endpoint.key()] !== clientRelay) {
                relay.close()
                return
            }
            if (!clientRelay.publishRelay(relay)) return
            inFlightIo.unregister(controlSocket)
            installed = true
            clientRelay.failedUntilMs.set(0L)
            registerUdpReceiver(clientRelay, relay)
            // Drain datagrams queued during open.
            while (true) {
                val pending = clientRelay.pollPending() ?: break
                when (
                    udpRelayReactor.send(
                        relay,
                        pending.remote,
                        pending.port,
                        pending.payload,
                    )
                ) {
                    UdpRelayReactor.SendResult.QUEUED -> Unit
                    UdpRelayReactor.SendResult.QUEUE_FULL ->
                        Log.w(TAG, "UDP relay send queue full; drop pending datagram")
                    UdpRelayReactor.SendResult.UNAVAILABLE ->
                        throw RejectedExecutionException("UDP relay reactor unavailable")
                }
            }
            Log.i(
                TAG,
                "SOCKS5 UDP ASSOCIATE ready client=${clientRelay.endpoint.ip.hostAddress}:${clientRelay.endpoint.port}",
            )
        } catch (error: Exception) {
            Log.w(TAG, "SOCKS5 UDP ASSOCIATE failed: ${error.message}")
            if (installed) {
                closeUdpRelay(clientRelay)
            } else if (!clientRelay.isClosed) {
                clientRelay.failedUntilMs.set(monotonicTimeMs() + associateFailBackoffMs)
                clientRelay.clearPending()
            }
        } finally {
            inFlightIo.unregister(controlSocket)
            clientRelay.finishOpening()
        }
    }

    private fun registerUdpReceiver(clientRelay: UdpClientRelay, relay: Socks5UdpRelay) {
        val endpoint = clientRelay.endpoint
        if (
            !udpRelayReactor.register(
                relay = relay,
                onDatagram = { datagram ->
                    if (
                        udpRelays[endpoint.key()] !== clientRelay ||
                            clientRelay.isClosed
                    ) {
                        return@register
                    }
                    // Demux is implicit: this relay only carries traffic for [endpoint].
                    enqueuePacket(
                        if (endpoint.ipv6) {
                            Packet.buildIp6Udp(
                                source = datagram.remote,
                                destination = endpoint.ip,
                                sourcePort = datagram.remotePort,
                                destPort = endpoint.port,
                                payload = datagram.payload,
                            )
                        } else {
                            Packet.buildIp4Udp(
                                source = datagram.remote,
                                destination = endpoint.ip,
                                sourcePort = datagram.remotePort,
                                destPort = endpoint.port,
                                payload = datagram.payload,
                            )
                        },
                    )
                    udpClients.noteActivity(endpoint)
                },
                onClosed = { closeUdpRelay(clientRelay) },
            )
        ) {
            throw RejectedExecutionException("UDP relay reactor unavailable")
        }
    }

    private fun forwardDnsDirect(
        clientIp: InetAddress,
        clientPort: Int,
        dnsServer: InetAddress,
        payload: ByteArray,
        ipv6: Boolean,
    ) {
        val socket = DatagramSocket()
        if (!inFlightIo.register(socket)) return
        try {
            val target =
                when {
                    dnsServer.isAnyLocalAddress -> dnsUpstream
                    dnsServer.hostAddress == "0.0.0.0" -> dnsUpstream
                    dnsServer.hostAddress == "::" -> dnsUpstream
                    else -> dnsServer
                }
            val bytes =
                ProtectedDatagramExchange.exchangeWithSocket(
                    socket = socket,
                    target = target,
                    targetPort = 53,
                    request = payload,
                    protect = { socket -> vpnService.protect(socket) },
                )
            // Reply source is the DNS server the client addressed (or upstream).
            val replySource = if (target == dnsUpstream) dnsServer else target
            val packet =
                if (ipv6) {
                    Packet.buildIp6Udp(
                        source = replySource,
                        destination = clientIp,
                        sourcePort = 53,
                        destPort = clientPort,
                        payload = bytes,
                    )
                } else {
                    Packet.buildIp4Udp(
                        source = replySource,
                        destination = clientIp,
                        sourcePort = 53,
                        destPort = clientPort,
                        payload = bytes,
                    )
                }
            enqueuePacket(packet)
        } catch (error: Exception) {
            if (running.get()) Log.w(TAG, "DNS direct forward failed: ${error.message}")
        } finally {
            inFlightIo.unregister(socket)
        }
    }

    private fun closeExpiredUdpRelay(endpoint: UdpClientEndpointTable.Endpoint) {
        val clientRelay = udpRelays[endpoint.key()] ?: return
        closeUdpRelay(clientRelay)
    }

    private fun closeUdpRelay(clientRelay: UdpClientRelay) {
        udpRelays.remove(clientRelay.endpoint.key(), clientRelay)
        clientRelay.currentRelay()?.let(udpRelayReactor::unregister)
        clientRelay.close()
    }

    private fun purgeIdleUdpClients() {
        if (!running.get()) return
        udpClients.purgeExpired(::closeExpiredUdpRelay)
    }

    private fun closeAllUdpRelays() {
        for (key in udpRelays.keys.toList()) {
            val r = udpRelays.remove(key)
            r?.close()
        }
        udpClients.clear()
    }

    // endregion

    private fun retransmitDueTcpSegments() {
        if (!running.get()) return
        val nowMs = monotonicTimeMs()
        for ((key, session) in sessions.entries) {
            if (
                sessions[key] === session &&
                    session.windowUpdatePending.compareAndSet(true, false) &&
                    !enqueueAck(session)
            ) {
                session.windowUpdatePending.set(true)
            }
            if (
                sessions[key] === session &&
                    !session.handshake.isComplete &&
                    session.handshakeDeadlineMs > 0L &&
                    nowMs >= session.handshakeDeadlineMs
            ) {
                Log.w(TAG, "TCP handshake timed out for $key")
                removeSession(key, session)
                continue
            }
            when (val due = session.retransmissions.pollDue(nowMs)) {
                is TcpRetransmissionQueue.PollResult.Retransmit -> {
                    if (sessions[key] !== session) continue
                    enqueueTcpRetransmission(key, session, due, reason = "timeout")
                }
                TcpRetransmissionQueue.PollResult.Exhausted -> {
                    Log.w(TAG, "TCP retransmission limit reached for $key")
                    rejectTcpSession(key, session)
                }
                null -> Unit
            }
            if (
                sessions[key] === session &&
                    session.closeState.isExpired(nowMs, SERVER_HALF_CLOSE_TIMEOUT_MS)
            ) {
                Log.w(TAG, "TCP half-close timed out for $key")
                rejectTcpSession(key, session)
            }
        }
    }

    private fun enqueueTcpRetransmission(
        key: String,
        session: TcpSession,
        due: TcpRetransmissionQueue.PollResult.Retransmit,
        reason: String,
    ) {
        if (sessions[key] !== session) return
        val queued =
            enqueuePacket(
                buildTcpPacket(
                    session = session,
                    seq = due.sequence,
                    ack = session.clientNextSeq,
                    flags = due.flags,
                    payload = due.payload,
                    maximumSegmentSize =
                        if (due.flags and Packet.SYN != 0) {
                            TcpSegmentSizer.maxPayloadBytes(mtu, session.ipv6)
                        } else {
                            null
                        },
                    windowScale =
                        if (due.flags and Packet.SYN != 0 && session.clientWindowScale != null) {
                            SERVER_WINDOW_SCALE
                        } else {
                            null
                        },
                ),
                lossless = true,
                timeoutMs = 0L,
            )
        if (!queued) {
            session.retransmissions.deferRetransmission(due, monotonicTimeMs())
            Log.w(TAG, "TCP $reason retransmission deferred by TUN backpressure for $key")
        }
    }

    private fun enqueueAck(session: TcpSession): Boolean =
        enqueuePacket(
            buildTcpPacket(
                session = session,
                seq = session.serverSeq,
                ack = session.clientNextSeq,
                flags = Packet.ACK,
                payload = ByteArray(0),
            ),
        )

    private fun enqueueChallengeAck(session: TcpSession) {
        if (session.challengeAcks.tryAcquire(monotonicTimeMs())) enqueueAck(session)
    }

    private fun enqueuePacket(
        packet: ByteArray,
        lossless: Boolean = false,
        timeoutMs: Long = if (lossless) LOSSLESS_ENQUEUE_TIMEOUT_MS else 0L,
    ): Boolean =
        running.get() &&
            outboundPackets.offer(
                packet = packet,
                lossless = lossless,
                timeoutMs = timeoutMs,
            )

    private fun removeSession(key: String, session: TcpSession) {
        if (sessions.remove(key, session)) {
            activeSessionCount.updateAndGet { (it - 1).coerceAtLeast(0) }
        }
        session.close()
    }

    private fun key(
        src: InetAddress,
        srcPort: Int,
        dst: InetAddress,
        dstPort: Int,
    ): String = "${src.hostAddress}:$srcPort-${dst.hostAddress}:$dstPort"

    private class TcpSession(
        val clientIp: InetAddress,
        val clientPort: Int,
        val remoteIp: InetAddress,
        val remotePort: Int,
        val clientIsn: Long,
        val clientMaximumSegmentSize: Int? = null,
        val clientWindowScale: Int? = null,
        val ipv6: Boolean = false,
    ) {
        @Volatile var socket: Socket? = null
        @Volatile var serverIsn: Long = 0
        @Volatile var serverSeq: Long = 0
        @Volatile var clientNextSeq: Long = 0
        @Volatile var handshakeDeadlineMs: Long = 0
        val handshake = TcpHandshakeGate()
        val sendWindow = TcpSendWindow()
        val retransmissions = TcpRetransmissionQueue()
        val closeState = TcpCloseState()
        val challengeAcks = TcpChallengeAckLimiter()
        val windowUpdatePending = AtomicBoolean(false)
        val upstream = TcpUpstreamQueue()
        val outputShutdown = AtomicBoolean(false)
        val downstreamReaderStarted = AtomicBoolean(false)
        val upstreamWriterActive = AtomicBoolean(false)

        fun close() {
            handshake.cancel()
            sendWindow.cancel()
            retransmissions.cancel()
            upstream.cancel()
            try {
                socket?.close()
            } catch (_: Exception) {
            }
            socket = null
        }
    }

    /**
     * One SOCKS5 UDP ASSOCIATE per local client endpoint so replies demux by relay socket.
     */
    private class UdpClientRelay(
        val endpoint: UdpClientEndpointTable.Endpoint,
    ) : AutoCloseable {
        private val lifecycle = CloseableRelaySlot<Socks5UdpRelay>()
        private val opening = AtomicBoolean(false)
        val failedUntilMs = AtomicLong(0L)
        private val pending = LinkedBlockingQueue<PendingUdp>(PENDING_CAP)

        val isClosed: Boolean
            get() = lifecycle.isClosed

        fun currentRelay(): Socks5UdpRelay? = lifecycle.current()

        fun publishRelay(relay: Socks5UdpRelay): Boolean = lifecycle.publish(relay)

        fun tryStartOpening(): Boolean {
            if (isClosed || !opening.compareAndSet(false, true)) return false
            if (!isClosed) return true
            opening.set(false)
            return false
        }

        fun finishOpening() {
            opening.set(false)
        }

        fun offerPending(remote: InetAddress, port: Int, payload: ByteArray): Boolean {
            if (isClosed) return false
            val pendingDatagram = PendingUdp(remote, port, payload)
            if (!pending.offer(pendingDatagram)) {
                pending.poll()
                pending.offer(pendingDatagram)
            }
            if (!isClosed) return true
            pending.remove(pendingDatagram)
            return false
        }

        fun pollPending(): PendingUdp? = if (isClosed) null else pending.poll()

        fun clearPending() {
            pending.clear()
        }

        override fun close() {
            lifecycle.close()
            clearPending()
        }

        data class PendingUdp(
            val remote: InetAddress,
            val port: Int,
            val payload: ByteArray,
        )
    }

    companion object {
        private const val TAG = "Tun2SocksEngine"
        private const val PENDING_CAP = 8
        private const val LOSSLESS_ENQUEUE_TIMEOUT_MS = 1_000L
        private const val HANDSHAKE_TIMEOUT_MS = 10_000L
        private const val WINDOW_WAIT_POLL_MS = 1_000L
        private const val RETRANSMISSION_SCAN_MS = 200L
        private const val RETRANSMISSION_DRAIN_TIMEOUT_MS = 35_000L
        private const val SERVER_FIN_WINDOW_TIMEOUT_MS = 30_000L
        private const val SERVER_HALF_CLOSE_TIMEOUT_MS = 60_000L
        private const val SERVER_WINDOW_SCALE = 0
        private const val UPSTREAM_POLL_MS = 200L
        private const val UPSTREAM_WRITER_IDLE_MS = 1_000L
        private const val STOP_TIMEOUT_MS = 2_000L
        private const val UDP_IDLE_CLEANUP_INTERVAL_MS = 5_000L
        private const val UDP_RELAY_OPERATION_ATTEMPTS = 2

        private fun monotonicTimeMs(): Long = System.nanoTime() / 1_000_000L
    }
}
