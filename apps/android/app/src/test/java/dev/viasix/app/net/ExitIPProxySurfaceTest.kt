package dev.viasix.app.net

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ExitIPProxySurfaceTest {
    @Test
    fun runningDetectionUsesMixedProxyForPrimaryAndGeoRequests() {
        val detector =
            resolve(
                "src/main/java/dev/viasix/app/net/ExitIPDetector.kt",
                "app/src/main/java/dev/viasix/app/net/ExitIPDetector.kt",
            ).readText()
        val activity =
            resolve(
                "src/main/java/dev/viasix/app/MainActivity.kt",
                "app/src/main/java/dev/viasix/app/MainActivity.kt",
            ).readText()
        val overview =
            resolve(
                "src/main/java/dev/viasix/app/ui/screens/OverviewScreen.kt",
                "app/src/main/java/dev/viasix/app/ui/screens/OverviewScreen.kt",
            ).readText()
        val settings =
            resolve(
                "src/main/java/dev/viasix/app/ui/screens/SettingsScreen.kt",
                "app/src/main/java/dev/viasix/app/ui/screens/SettingsScreen.kt",
            ).readText()

        assertTrue(detector.contains("URL(url).openConnection(proxy.asJavaProxy())"))
        assertTrue(detector.contains("request.get(endpoint, timeoutMs, proxy)"))
        assertTrue(detector.contains("validateExpectedFamily"))
        assertTrue(detector.contains("detectionAttemptModes"))
        assertTrue(detector.contains("ExitIPDetectionMode.IPV6"))
        assertTrue(activity.contains("ExitIPRoutePolicy.proxyForRuntime"))
        assertTrue(activity.contains("running = state.runtime.running"))
        assertTrue(activity.contains("mixedPort = state.runtime.mixedPort"))
        assertTrue(activity.contains("proxy = proxy"))
        assertTrue(activity.contains("requestIsCurrent"))
        assertTrue(activity.contains("已忽略旧结果"))
        assertTrue(overview.contains("info.route.label"))
        assertTrue(settings.contains("info.route.label"))
    }

    private fun resolve(vararg paths: String): File =
        paths.map { File(it) }.firstOrNull { it.isFile }
            ?: error("file not found from cwd=${File(".").absolutePath}: ${paths.toList()}")
}
