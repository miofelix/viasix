package dev.viasix.app.session

internal enum class ShutdownSubmission {
    START_NOW,
    QUEUED,
}

/** Coordinates service teardown with the newest start request. */
internal class ShutdownRestartGate<T : Any> {
    private val monitor = Any()
    private var shuttingDown = false
    private var teardownFinished = false
    private var stopCommitted = false
    private var pendingRestart: T? = null

    fun beginShutdown(): Boolean =
        synchronized(monitor) {
            if (shuttingDown) {
                false
            } else {
                shuttingDown = true
                teardownFinished = false
                stopCommitted = false
                pendingRestart = null
                true
            }
        }

    fun submit(request: T): ShutdownSubmission =
        synchronized(monitor) {
            if (!shuttingDown || teardownFinished || stopCommitted) {
                resetForStart()
                ShutdownSubmission.START_NOW
            } else {
                pendingRestart = request
                ShutdownSubmission.QUEUED
            }
        }

    /** Returns the newest queued restart, or null when the service may stop. */
    fun completeTeardown(): T? =
        synchronized(monitor) {
            check(shuttingDown) { "teardown completed without an active shutdown" }
            pendingRestart?.also {
                pendingRestart = null
                resetForStart()
            } ?: run {
                teardownFinished = true
                null
            }
        }

    /** Commits the stop only if no newer start cancelled it. */
    fun commitServiceStop(): Boolean =
        synchronized(monitor) {
            if (!shuttingDown || !teardownFinished) {
                false
            } else {
                stopCommitted = true
                true
            }
        }

    fun isShuttingDown(): Boolean = synchronized(monitor) { shuttingDown }

    private fun resetForStart() {
        shuttingDown = false
        teardownFinished = false
        stopCommitted = false
        pendingRestart = null
    }
}
