package dev.viasix.app.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class RoutingModePatchSurfaceTest {
    @Test
    fun liveModePatchIsSingleFlightAndBoundToOneRuntimeSession() {
        val activity =
            resolve(
                "src/main/java/dev/viasix/app/MainActivity.kt",
                "app/src/main/java/dev/viasix/app/MainActivity.kt",
            ).readText()
        val state =
            resolve(
                "src/main/java/dev/viasix/app/state/SessionUiState.kt",
                "app/src/main/java/dev/viasix/app/state/SessionUiState.kt",
            ).readText()
        val overview =
            resolve(
                "src/main/java/dev/viasix/app/ui/screens/OverviewScreen.kt",
                "app/src/main/java/dev/viasix/app/ui/screens/OverviewScreen.kt",
            ).readText()
        val patch =
            activity.substringAfter("fun patchRoutingMode(mode: RoutingMode)")
                .substringBefore("fun copyText(")

        assertTrue(state.contains("val routingModeSyncing: Boolean = false"))
        assertTrue(patch.contains("state.routingModeSyncing"))
        assertTrue(patch.contains("state.connectionPhase.isBusy"))
        assertTrue(patch.contains("val routingSessionKey = runtime.sessionKey()"))
        assertTrue(patch.contains("port = routingSessionKey.controllerPort"))
        assertTrue(patch.contains("secret = routingSessionKey.secret"))
        assertTrue(patch.contains("runtimeStore.load().sessionKey() == routingSessionKey"))
        assertTrue(patch.contains("current.copy(routingModeSyncing = false)"))
        assertTrue(patch.contains("ControllerClient.updateRoutingMode("))
        assertTrue(patch.contains("result.restartRequired"))
        assertTrue(patch.contains("startVpn(reason = \"routing-mode\")"))
        assertFalse(patch.contains("getSharedPreferences"))
        assertFalse(patch.contains("state.runtime.controllerPort"))

        assertTrue(
            overview.contains(
                "!state.routingModeSyncing && !state.connectionPhase.isBusy",
            ),
        )
        assertTrue(overview.contains("enabled = routingModeEnabled"))
        assertTrue(overview.contains("正在同步运行中的代理模式…"))
    }

    private fun resolve(vararg paths: String): File =
        paths.map { File(it) }.firstOrNull { it.isFile }
            ?: error("file not found from cwd=${File(".").absolutePath}: ${paths.toList()}")
}
