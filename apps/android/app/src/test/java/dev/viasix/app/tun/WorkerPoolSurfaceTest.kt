package dev.viasix.app.tun

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class WorkerPoolSurfaceTest {
    @Test
    fun tunBlockingWorkUsesHardCappedPoolsAndExplicitRejectionPaths() {
        val engine =
            resolve(
                "src/main/java/dev/viasix/app/tun/Tun2SocksEngine.kt",
                "app/src/main/java/dev/viasix/app/tun/Tun2SocksEngine.kt",
            ).readText()

        assertFalse(engine.contains("newCachedThreadPool"))
        assertTrue(engine.contains("maxConnectionWorkers: Int = 16"))
        // Io pool must cover the session admission limit: readers pin one
        // thread per live TCP session, writers need transient headroom.
        assertTrue(engine.contains("maxIoWorkers: Int = maxSessions + 64"))
        assertTrue(engine.contains("connectionWorkers.execute { openTcpSession(key, session) }"))
        assertTrue(engine.contains("ioWorkers.execute { writeTcpUpstream(key, session, socket) }"))
        assertTrue(engine.contains("Socks5Client.connectWithSocket"))
        assertTrue(engine.contains("ProtectedSocketConnector.connectWithSocket"))
        assertTrue(engine.contains("Socks5UdpRelay.openWithControlSocket"))
        assertTrue(engine.contains("ProtectedDatagramExchange.exchangeWithSocket"))
        assertTrue(engine.contains("inFlightIo.register"))
        assertTrue(engine.contains("rejectTcpSession(key, session)"))
        assertTrue(engine.contains("direct DNS worker limit reached; drop"))
        assertTrue(engine.contains("UDP ASSOCIATE worker limit reached; backoff"))
    }

    private fun resolve(vararg paths: String): File =
        paths.map { File(it) }.firstOrNull { it.isFile }
            ?: error("file not found from cwd=${File(".").absolutePath}: ${paths.toList()}")
}
