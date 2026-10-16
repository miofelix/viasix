package dev.viasix.app.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class VpnTrafficSupervisorSurfaceTest {
    @Test
    fun restartedSessionCannotReviveEarlierTrafficSupervisor() {
        val service =
            resolve(
                "src/main/java/dev/viasix/app/vpn/ViaSixVpnService.kt",
                "app/src/main/java/dev/viasix/app/vpn/ViaSixVpnService.kt",
            ).readText()

        assertTrue(service.contains("private val trafficLoopGate = GenerationGate()"))
        assertTrue(service.contains("val generation = trafficLoopGate.next()"))
        assertTrue(service.contains("val sampler = TrafficSampler(maxHistory = 30)"))
        assertTrue(service.contains("while (trafficLoopGate.isCurrent(generation))"))
        assertTrue(service.contains("trafficLoopGate.claimAndRun(generation, runtimeStackLock)"))
        assertTrue(service.contains("trafficLoopGate.invalidate()"))
        assertFalse(service.contains("trafficLoopRunning.set(true)"))
        assertFalse(service.contains("private val trafficSampler"))
    }

    private fun resolve(vararg paths: String): File =
        paths.map { File(it) }.firstOrNull { it.isFile }
            ?: error("file not found from cwd=${File(".").absolutePath}: ${paths.toList()}")
}
