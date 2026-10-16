package dev.viasix.app.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class GenerationGateTest {
    @Test
    fun newerGenerationCannotBeConfusedWithEarlierWork() {
        val gate = GenerationGate()
        val first = gate.next()
        val second = gate.next()

        assertFalse(gate.isCurrent(first))
        assertTrue(gate.isCurrent(second))
        assertFalse(gate.claim(first))
    }

    @Test
    fun invalidatePermanentlyRetiresCurrentGeneration() {
        val gate = GenerationGate()
        val generation = gate.next()

        gate.invalidate()

        assertFalse(gate.isCurrent(generation))
        assertFalse(gate.claim(generation))
    }

    @Test
    fun terminalActionCanOnlyBeClaimedOnce() {
        val gate = GenerationGate()
        val generation = gate.next()

        assertTrue(gate.claim(generation))
        assertFalse(gate.isCurrent(generation))
        assertFalse(gate.claim(generation))
    }

    @Test
    fun oldSupervisorWaitingForStackLockCannotStopTheReplacementSession() {
        val gate = GenerationGate()
        val stackLock = Any()
        val oldGeneration = gate.next()
        val waiting = CountDownLatch(1)
        val stoppedNewSession = AtomicBoolean(false)
        lateinit var supervisor: Thread
        synchronized(stackLock) {
            supervisor = thread {
                waiting.countDown()
                gate.claimAndRun(oldGeneration, stackLock) { stoppedNewSession.set(true) }
            }
            assertTrue(waiting.await(2, TimeUnit.SECONDS))
            gate.invalidate()
            gate.next() // Publish the replacement while the old supervisor waits.
        }
        supervisor.join(2_000)
        assertFalse(supervisor.isAlive)
        assertFalse(stoppedNewSession.get())
    }

    @Test
    fun claimedShutdownFinishesBeforeAReplacementCanAcquireItsResources() {
        val gate = GenerationGate()
        val stackLock = Any()
        val generation = gate.next()
        val shutdownStarted = CountDownLatch(1)
        val releaseShutdown = CountDownLatch(1)
        val replacementStarted = CountDownLatch(1)
        val shutdownFinished = AtomicBoolean(false)
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable>()
        val supervisor = thread {
            try {
                gate.claimAndRun(generation, stackLock) {
                    shutdownStarted.countDown()
                    check(releaseShutdown.await(2, TimeUnit.SECONDS))
                    shutdownFinished.set(true)
                }
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        var replacement: Thread? = null
        try {
            assertTrue(shutdownStarted.await(2, TimeUnit.SECONDS))
            replacement = thread {
                synchronized(stackLock) {
                    if (!shutdownFinished.get()) failure.set(AssertionError("replacement overlapped shutdown"))
                    gate.next()
                    replacementStarted.countDown()
                }
            }
            assertFalse(replacementStarted.await(100, TimeUnit.MILLISECONDS))
            releaseShutdown.countDown()
            assertTrue(replacementStarted.await(2, TimeUnit.SECONDS))
        } finally {
            releaseShutdown.countDown()
            supervisor.join(2_000)
            replacement?.join(2_000)
        }
        assertFalse(supervisor.isAlive)
        assertFalse(replacement?.isAlive == true)
        failure.get()?.let { throw AssertionError("lifecycle worker failed", it) }
    }
}
