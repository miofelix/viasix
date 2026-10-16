package dev.viasix.app.session

import dev.viasix.app.state.SessionUiState
import dev.viasix.app.cfst.CfstRunOutcome
import dev.viasix.app.ui.AppSection
import dev.viasix.app.ui.SpeedNumericField
import dev.viasix.core.speedtest.SpeedTestParameters
import java.io.File
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionViewModelTest {
    @Test
    fun seedsOnceThenIgnoresLaterSeeds() {
        val vm = SessionViewModel()
        assertFalse("fresh ViewModel must not be seeded", vm.isSeeded)

        val first = SessionUiState(selectedAddress = "2606:4700::1")
        vm.seedIfNeeded(first, AppSection.NODES)
        assertTrue(vm.isSeeded)
        assertEquals("2606:4700::1", vm.stateHolder.value.selectedAddress)
        assertEquals(AppSection.NODES, vm.sectionHolder.value)

        // A second seed (a rotation recreating the Activity) must be a no-op so
        // live in-memory state is never clobbered by values rebuilt from stores.
        val second = SessionUiState(selectedAddress = "2001:db8::99")
        vm.seedIfNeeded(second, AppSection.PROFILES)
        assertEquals("2606:4700::1", vm.stateHolder.value.selectedAddress)
        assertEquals(AppSection.NODES, vm.sectionHolder.value)
    }

    @Test
    fun mutationsAfterSeedSurviveThroughTheSameHolder() {
        val vm = SessionViewModel()
        vm.seedIfNeeded(SessionUiState(), AppSection.OVERVIEW)

        // Simulate an in-flight coroutine writing results after a rotation: the
        // retained holder is the single source of truth, so the write is visible
        // to any new composition reading the same holder.
        val holderBeforeRotation = vm.stateHolder
        holderBeforeRotation.value =
            holderBeforeRotation.value.copy(statusMessage = "测速完成")

        assertSame("holder identity must be stable across recreation", holderBeforeRotation, vm.stateHolder)
        assertEquals("测速完成", vm.stateHolder.value.statusMessage)
    }

    @Test
    fun runnerIsRetainedAndIdleByDefault() {
        val vm = SessionViewModel()
        // A freshly-built runner is not running, so cancel requests are no-ops.
        assertFalse(vm.cfstRunner.isRunning)
        assertFalse(vm.cfstRunner.requestCancel())
    }

    @Test
    fun incompleteSpeedParametersSurviveReseeding() {
        val vm = SessionViewModel()
        vm.seedIfNeeded(SessionUiState(), AppSection.NODES)
        vm.speedParameterInputs.edit(SpeedNumericField.PORT, "", "443", valid = false)

        vm.seedIfNeeded(SessionUiState(), AppSection.OVERVIEW)

        assertEquals("", vm.speedParameterInputs.text(SpeedNumericField.PORT, "443"))
        assertTrue(vm.speedParameterInputs.validationMessage(vm.stateHolder.value.speedTest.parameters) != null)
    }

    @Test
    fun stopDuringInitializationPreventsTheLaterProcessFromStarting() {
        val vm = SessionViewModel()
        val work = createTempDirectory("cfst-initialization-cancel").toFile()
        val marker = File(work, "started")
        val binary = File(work, "cfst").apply {
            writeText("#!/bin/sh\ntouch started\n")
            setExecutable(true)
        }
        try {
            // The UI has begun initialization, while no runner/process exists yet.
            val cancellation = vm.beginSpeedTest()
            assertFalse(vm.cfstRunner.isRunning)
            assertTrue(vm.cancelSpeedTest())

            // The installer finishes later. The durable request reaches the runner.
            val outcome = vm.cfstRunner.run(
                binary = binary,
                workDir = work,
                parameters = SpeedTestParameters.defaultsForRange(),
                isCancellationRequested = { cancellation.isRequested },
            )
            assertEquals(CfstRunOutcome.Cancelled, outcome)
            assertFalse("stopping initialization must prevent a process launch", marker.exists())

            vm.finishSpeedTest(cancellation)
            assertFalse(vm.cancelSpeedTest())
            val next = vm.beginSpeedTest()
            assertFalse("a new run must not inherit the previous cancellation", next.isRequested)
            vm.finishSpeedTest(next)
        } finally {
            work.deleteRecursively()
        }
    }
}
