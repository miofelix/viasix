package dev.viasix.app.state

import dev.viasix.app.prefs.DefaultProfile
import dev.viasix.app.prefs.SessionPrefs
import dev.viasix.app.session.SessionStartGate
import dev.viasix.core.projection.MihomoProjection
import dev.viasix.core.projection.ProjectOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DefaultProfileTest {
    @Test
    fun firstLaunchAndResetAreReadyWithoutImportingAProfile() {
        val prefs = SessionPrefs()
        val state = SessionUiState.fromPrefs(prefs)

        assertEquals(DefaultProfile.yaml, prefs.profileYaml)
        assertEquals(DefaultProfile.selectedAddress, prefs.selectedAddress)
        assertEquals(DefaultProfile.yaml, state.profileDraft)
        assertTrue(state.configurationReady)
        assertFalse(state.profileHasUnsavedChanges)
        assertEquals(
            SessionStartGate.Result.Ok,
            SessionStartGate.evaluate(state.routingMode, state.selectedAddress, state.profileYaml),
        )
    }

    @Test
    fun suppliedProfileKeepsTransportTlsAndUdpPolicyWhenProjected() {
        val projected = MihomoProjection.project(
            DefaultProfile.yaml,
            ProjectOptions(selectedAddress = DefaultProfile.selectedAddress),
        )
        val proxy = (projected["proxies"] as List<*>).single() as Map<*, *>

        assertEquals("ViaSix Cloudflare Pages", proxy["name"])
        assertEquals("vless", proxy["type"])
        assertEquals(DefaultProfile.selectedAddress, proxy["server"])
        assertEquals(443, proxy["port"])
        assertEquals("ws", proxy["network"])
        assertEquals(true, proxy["tls"])
        assertEquals(false, proxy["skip-cert-verify"])
        assertEquals(false, proxy["udp"])
        assertEquals("viasix.miofelix.com", proxy["servername"])
        val ws = proxy["ws-opts"] as Map<*, *>
        assertEquals("/?ed=2560", ws["path"])
        assertEquals("viasix.miofelix.com", (ws["headers"] as Map<*, *>)["Host"])
    }

    @Test
    fun customProfileAndIndependentDraftRemainIntact() {
        val custom = DefaultProfile.yaml.replace("ViaSix Cloudflare Pages", "Personal Edge")
        val draft = custom.replace("chrome", "firefox")
        val state = SessionUiState.fromPrefs(SessionPrefs(profileYaml = custom, profileDraft = draft))

        assertEquals(custom, state.profileYaml)
        assertEquals(draft, state.profileDraft)
        assertTrue(state.profileHasUnsavedChanges)
    }
}
