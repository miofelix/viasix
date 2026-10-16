package dev.viasix.app.session

import java.util.concurrent.atomic.AtomicLong

/** Explicit service stops invalidate permission continuations from every UI entry point. */
class PermissionStartCancellation(private val processToken: String = RuntimeProcessIdentity.token) {
    private val generation = AtomicLong(0L)

    fun capture(): String = "$processToken:${generation.get()}"

    fun isCurrent(token: String): Boolean = token == capture()

    fun cancel() {
        generation.incrementAndGet()
    }

    companion object {
        val shared = PermissionStartCancellation()
    }
}
