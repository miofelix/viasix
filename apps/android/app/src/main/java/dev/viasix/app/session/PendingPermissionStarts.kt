package dev.viasix.app.session

/** Permission results may arrive after the user has cancelled the connection attempt. */
class PendingPermissionStarts(
    private val cancellation: PermissionStartCancellation = PermissionStartCancellation.shared,
) {
    private var pendingVpnReason: String? = null
    private var pendingNotificationReason: String? = null

    var generationToken: String = cancellation.capture()
        private set

    val isCurrent: Boolean
        get() = cancellation.isCurrent(generationToken)

    var vpnReason: String?
        get() = pendingVpnReason.takeIf { isCurrent }
        set(value) {
            if (value != null) beginCurrentAttempt()
            pendingVpnReason = value
        }

    var notificationReason: String?
        get() = pendingNotificationReason.takeIf { isCurrent }
        set(value) {
            if (value != null) beginCurrentAttempt()
            pendingNotificationReason = value
        }

    /** Preserve rotation, while rejecting bundles from an earlier stop or app process. */
    fun restore(vpnReason: String?, notificationReason: String?, token: String?) {
        generationToken = token ?: cancellation.capture()
        pendingVpnReason = vpnReason.takeIf { token != null && isCurrent }
        pendingNotificationReason = notificationReason.takeIf { token != null && isCurrent }
    }

    private fun beginCurrentAttempt() {
        if (!isCurrent) cancel()
        generationToken = cancellation.capture()
    }

    fun takeVpnReason(granted: Boolean): String? {
        val pending = vpnReason
        vpnReason = null
        return pending.takeIf { granted }
    }

    fun takeNotificationReason(): String? {
        val pending = notificationReason
        notificationReason = null
        return pending
    }

    fun cancel() {
        pendingVpnReason = null
        pendingNotificationReason = null
    }
}
