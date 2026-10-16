package dev.viasix.app.tun

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DirectDnsConcurrencySurfaceTest {
    @Test
    fun explicitDirectDnsHasBoundedInflightQueries() {
        val engine =
            resolve(
                "src/main/java/dev/viasix/app/tun/Tun2SocksEngine.kt",
                "app/src/main/java/dev/viasix/app/tun/Tun2SocksEngine.kt",
            ).readText()

        assertTrue(engine.contains("maxDirectDnsQueries: Int = 32"))
        assertTrue(engine.contains("directDnsGate.tryAcquire()"))
        assertTrue(engine.contains("permit.close()"))
        assertTrue(engine.contains("RejectedExecutionException"))
        assertTrue(engine.contains("DNS query limit reached; drop"))
    }

    private fun resolve(vararg paths: String): File =
        paths.map { File(it) }.firstOrNull { it.isFile }
            ?: error("file not found from cwd=${File(".").absolutePath}: ${paths.toList()}")
}
