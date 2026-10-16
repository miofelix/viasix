package dev.viasix.app.session

import dev.viasix.app.state.RuntimeSnapshot
import dev.viasix.app.state.SessionUiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionConfigurationActionsTest {
    private fun state(phase: ConnectionPhase) = SessionUiState(
        profileYaml = "applied profile",
        profileDraft = "edited profile",
        selectedAddress = "2606:4700::1",
        candidateAddresses = listOf("2606:4700::1"),
        configPreview = "old preview",
        connectionPhase = phase,
        // During restart, the last runtime snapshot can still report running.
        runtime = RuntimeSnapshot(running = phase != ConnectionPhase.STOPPED),
    )

    @Test
    fun applyingWhileConnectingOrStoppingPreservesBothAppliedAndDraftProfiles() {
        listOf(ConnectionPhase.STARTING, ConnectionPhase.STOPPING).forEach { phase ->
            val before = state(phase)
            val after = SessionConfigurationActions.applyProfile(before, "replacement")

            assertSame(before, after)
            assertEquals("applied profile", after.toPrefs().profileYaml)
            assertEquals("edited profile", after.toPrefs().profileDraft)
        }
    }

    @Test
    fun reconnectDuringATransitionCannotSilentlySaveANodeThatWasNeverStarted() {
        listOf(ConnectionPhase.STARTING, ConnectionPhase.STOPPING).forEach { phase ->
            val before = state(phase)
            val after = SessionConfigurationActions.selectNode(before, "2606:4700::2", reconnect = true)

            assertFalse(SessionConfigurationActions.canReconnect(before))
            assertSame(before, after)
            assertEquals(listOf("2606:4700::1"), after.toPrefs().candidateAddresses)
            assertEquals("2606:4700::1", after.toPrefs().selectedAddress)
        }
    }

    @Test
    fun stableSessionsCanApplyProfilesAndSelectTheNextReconnectNode() {
        listOf(ConnectionPhase.STOPPED, ConnectionPhase.RUNNING).forEach { phase ->
            val before = state(phase)
            val applied = SessionConfigurationActions.applyProfile(before, "replacement")
            assertEquals("replacement", applied.toPrefs().profileYaml)
            assertEquals("replacement", applied.toPrefs().profileDraft)
            assertEquals("", applied.configPreview)
            assertSame(before.runtime, applied.runtime)

            val selected = SessionConfigurationActions.selectNode(applied, "[2606:4700::2]", reconnect = true)
            assertEquals("2606:4700::2", selected.selectedAddress)
            assertEquals("2606:4700::2", selected.candidateAddresses.first())
            assertEquals(phase == ConnectionPhase.RUNNING, SessionConfigurationActions.canReconnect(selected))
        }
    }

    @Test
    fun selectionWithoutReconnectCanStillPrepareTheNextSession() {
        val before = state(ConnectionPhase.STARTING)
        val selected = SessionConfigurationActions.selectNode(before, "2606:4700::2", reconnect = false)

        assertTrue(selected.selectedIsIpv6)
        assertEquals("2606:4700::2", selected.toPrefs().selectedAddress)
        assertSame(before.runtime, selected.runtime)
    }
}
