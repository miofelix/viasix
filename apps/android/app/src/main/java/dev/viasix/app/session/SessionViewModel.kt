package dev.viasix.app.session

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.ViewModel
import dev.viasix.app.cfst.CfstRunner
import dev.viasix.app.state.SessionUiState
import dev.viasix.app.ui.AppSection

/**
 * Retains ephemeral session state across configuration changes (rotation,
 * dark-mode toggle, locale change). Before this ViewModel existed, the state
 * lived in `remember { mutableStateOf(...) }` inside `setContent` and the
 * running CFST process ran in `rememberCoroutineScope()`, so a rotation wiped
 * speed-test results / logs / exit-IP and `onDestroy` cancelled an in-flight
 * CFST run. Holding them here means:
 *
 *  - [stateHolder] / [sectionHolder] survive recreation; the Activity binds to
 *    them via property delegation so every reader mutates the retained state.
 *  - [cfstRunner] keeps running through a configuration change; it is cancelled
 *    only in [onCleared] (true teardown), never in `Activity.onDestroy` (which
 *    also fires on rotation).
 *
 * This is a plain [ViewModel] (no Context): the holders and runner need none,
 * and Context-bound work stays in the Activity so the class remains unit-testable.
 */
class SessionViewModel : ViewModel() {
    /** Backing store for the whole UI state; bound in the Activity via `by`. */
    val stateHolder: MutableState<SessionUiState> = mutableStateOf(SessionUiState())

    /** Currently selected navigation section; also delegated in the Activity. */
    val sectionHolder: MutableState<AppSection> = mutableStateOf(AppSection.OVERVIEW)

    /** One-at-a-time CFST runner, retained so a run survives rotation. */
    val cfstRunner: CfstRunner = CfstRunner()

    private var seeded = false

    /** True once [seedIfNeeded] has run; exposed for tests and diagnostics. */
    val isSeeded: Boolean
        get() = seeded

    /**
     * Populate the holders exactly once, on the Activity's first `onCreate`.
     * On later recreations (rotation) the retained state is kept and the
     * provided values are ignored, so nothing computed from persisted stores
     * clobbers live in-memory state such as speed-test results.
     */
    fun seedIfNeeded(initialState: SessionUiState, initialSection: AppSection) {
        if (seeded) return
        stateHolder.value = initialState
        sectionHolder.value = initialSection
        seeded = true
    }

    override fun onCleared() {
        // Real teardown only (finish / process removal), never a config change.
        cfstRunner.requestCancel()
        super.onCleared()
    }
}
