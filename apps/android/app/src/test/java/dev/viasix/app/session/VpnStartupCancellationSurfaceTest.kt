package dev.viasix.app.session

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class VpnStartupCancellationSurfaceTest {
    @Test
    fun cancellationChecksFollowEveryOwnedStartupResource() {
        val service =
            resolve(
                "src/main/java/dev/viasix/app/vpn/ViaSixVpnService.kt",
                "app/src/main/java/dev/viasix/app/vpn/ViaSixVpnService.kt",
            ).readText()

        assertTrue(service.contains("catch (error: VpnStartupCancelledException)"))
        assertTrue(service.contains("shutdownGate.isShuttingDown()"))
        assertTrue(service.contains("shutdownGate.completeTeardown()"))
        assertTrue(service.contains("ShutdownSubmission.QUEUED"))
        assertTrue(service.contains("thread(name = \"viasix-vpn-stop\""))
        assertTrue(service.contains("stopForeground(STOP_FOREGROUND_REMOVE)"))
        assertTrue(service.contains("requireStartupActive(\"after mihomo launch\")"))
        assertTrue(service.contains("requireStartupActive(\"after VPN establish\")"))
        assertTrue(service.contains("requireStartupActive(\"after TUN forwarding launch\")"))
        assertTrue(service.contains("requireStartupActive(\"after traffic supervision launch\")"))

        val engineStarted = service.indexOf("engine.start()")
        val published = service.indexOf("phase = ConnectionPhase.RUNNING")
        assertTrue(engineStarted >= 0)
        assertTrue(published > engineStarted)
        assertTrue(service.contains("mihomo exited before VPN stack became ready"))
        assertTrue(service.contains("TUN forwarding exited before VPN stack became ready"))
        val startupWindow = service.substring(engineStarted, published)
        assertTrue(startupWindow.split("requireRuntimeStackHealthy(").size >= 3)
    }

    private fun resolve(vararg paths: String): File =
        paths.map { File(it) }.firstOrNull { it.isFile }
            ?: error("file not found from cwd=${File(".").absolutePath}: ${paths.toList()}")
}
