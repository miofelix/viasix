package dev.viasix.app.session

import java.util.concurrent.atomic.AtomicLong

/** Prevents asynchronous work from acting after a newer lifecycle generation starts. */
internal class GenerationGate {
    private val current = AtomicLong(0L)

    fun next(): Long = current.incrementAndGet()

    fun invalidate() {
        current.incrementAndGet()
    }

    fun isCurrent(generation: Long): Boolean = current.get() == generation

    /** Atomically reserves the terminal action for [generation] and invalidates it. */
    fun claim(generation: Long): Boolean = current.compareAndSet(generation, generation + 1L)

    /** Rechecks ownership under the same lock that protects replacement resources. */
    fun claimAndRun(generation: Long, lifecycleLock: Any, action: () -> Unit): Boolean =
        synchronized(lifecycleLock) {
            if (!claim(generation)) {
                false
            } else {
                action()
                true
            }
        }
}
