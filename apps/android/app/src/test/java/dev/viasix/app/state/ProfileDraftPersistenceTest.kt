package dev.viasix.app.state

import dev.viasix.app.prefs.SessionPrefs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileDraftPersistenceTest {
    @Test
    fun missingLegacyDraftStartsFromAppliedProfile() {
        val applied = SessionUiState.defaultProfile
        val state = SessionUiState.fromPrefs(SessionPrefs(profileYaml = applied, profileDraft = null))

        assertEquals(applied, state.profileYaml)
        assertEquals(applied, state.profileDraft)
        assertFalse(state.profileHasUnsavedChanges)
    }

    @Test
    fun independentDraftSurvivesPrefsRoundTripModel() {
        val applied = SessionUiState.defaultProfile
        val draft = applied.replace("ViaSix Cloudflare Pages", "Draft Edge")
        val state =
            SessionUiState.fromPrefs(
                SessionPrefs(profileYaml = applied, profileDraft = draft),
            )

        assertEquals(applied, state.profileYaml)
        assertEquals(draft, state.profileDraft)
        assertTrue(state.profileHasUnsavedChanges)
        assertEquals(applied, state.toPrefs().profileYaml)
        assertEquals(draft, state.toPrefs().profileDraft)
    }

    @Test
    fun notificationPromptHistorySurvivesPrefsModel() {
        val state =
            SessionUiState.fromPrefs(
                SessionPrefs(notificationPermissionRequested = true),
            )

        assertTrue(state.notificationPermission.wasRequested)
        assertTrue(state.toPrefs().notificationPermissionRequested)
    }
}
