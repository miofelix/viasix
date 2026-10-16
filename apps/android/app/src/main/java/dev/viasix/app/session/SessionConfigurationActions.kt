package dev.viasix.app.session

import dev.viasix.app.state.SessionUiState
import dev.viasix.app.state.rememberCandidate

/** Keeps saved selections aligned with actions that can actually reach the VPN service. */
object SessionConfigurationActions {
    fun canApply(phase: ConnectionPhase): Boolean = !phase.isBusy

    fun canReconnect(state: SessionUiState): Boolean =
        state.runtime.running && canApply(state.connectionPhase)

    fun applyProfile(state: SessionUiState, yaml: String): SessionUiState =
        if (canApply(state.connectionPhase)) {
            state.copy(profileYaml = yaml, profileDraft = yaml, configPreview = "")
        } else {
            state
        }

    fun selectNode(state: SessionUiState, address: String, reconnect: Boolean): SessionUiState =
        if (reconnect && !canApply(state.connectionPhase)) {
            state
        } else {
            state.rememberCandidate(address)
        }
}
