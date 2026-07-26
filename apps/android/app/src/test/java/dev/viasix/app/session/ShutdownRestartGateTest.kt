package dev.viasix.app.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShutdownRestartGateTest {
    @Test
    fun retainsOnlyLatestStartReceivedDuringTeardown() {
        val gate = ShutdownRestartGate<String>()
        assertTrue(gate.beginShutdown())

        assertEquals(ShutdownSubmission.QUEUED, gate.submit("old"))
        assertEquals(ShutdownSubmission.QUEUED, gate.submit("latest"))
        assertEquals("latest", gate.completeTeardown())
        assertFalse(gate.isShuttingDown())
        assertFalse(gate.commitServiceStop())
    }

    @Test
    fun startAfterTeardownCancelsPendingServiceStop() {
        val gate = ShutdownRestartGate<String>()
        assertTrue(gate.beginShutdown())
        assertNull(gate.completeTeardown())

        assertEquals(ShutdownSubmission.START_NOW, gate.submit("restart"))
        assertFalse(gate.isShuttingDown())
        assertFalse(gate.commitServiceStop())
    }

    @Test
    fun serviceStopCommitsOnlyAfterTeardownWithoutRestart() {
        val gate = ShutdownRestartGate<String>()
        assertTrue(gate.beginShutdown())
        assertNull(gate.completeTeardown())
        assertTrue(gate.commitServiceStop())

        assertEquals(ShutdownSubmission.START_NOW, gate.submit("late restart"))
        assertFalse(gate.isShuttingDown())
    }
}
