package dev.viasix.app.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PendingPermissionStartsTest {
    @Test
    fun stoppingBeforeNotificationPermissionResultCannotResumeTheConnection() {
        val starts = PendingPermissionStarts()
        val launched = mutableListOf<String>()
        starts.notificationReason = "connect"

        starts.cancel()
        starts.takeNotificationReason()?.let(launched::add)

        assertEquals(emptyList<String>(), launched)
        assertNull(starts.notificationReason)
    }

    @Test
    fun stoppingBeforeVpnConsentPreventsALateGrantFromStartingTheService() {
        val starts = PendingPermissionStarts()
        val launched = mutableListOf<String>()
        starts.vpnReason = "apply-profile"

        starts.cancel()
        starts.takeVpnReason(granted = true)?.let(launched::add)

        assertEquals(emptyList<String>(), launched)
        assertNull(starts.vpnReason)
    }

    @Test
    fun freshAttemptAfterCancellationCanAdvanceThroughBothPermissionsOnce() {
        val starts = PendingPermissionStarts()
        starts.notificationReason = "old-connect"
        starts.cancel()

        starts.notificationReason = "new-connect"
        starts.vpnReason = starts.takeNotificationReason()
        assertNull(starts.takeNotificationReason())
        assertEquals("new-connect", starts.takeVpnReason(granted = true))
        assertNull(starts.takeVpnReason(granted = true))
    }

    @Test
    fun deniedVpnConsentConsumesThePendingAttempt() {
        val starts = PendingPermissionStarts()
        starts.vpnReason = "connect"

        assertNull(starts.takeVpnReason(granted = false))
        assertNull(starts.takeVpnReason(granted = true))
    }

    @Test
    fun explicitServiceStopInvalidatesBothKindsOfPendingPermissionResult() {
        val cancellation = PermissionStartCancellation("test-process")
        val notificationActivity = PendingPermissionStarts(cancellation)
        val vpnActivity = PendingPermissionStarts(cancellation)
        notificationActivity.notificationReason = "notification-connect"
        vpnActivity.vpnReason = "vpn-connect"

        // This is the same operation used by the service's explicit ACTION_STOP.
        cancellation.cancel()

        assertNull(notificationActivity.takeNotificationReason())
        assertNull(vpnActivity.takeVpnReason(granted = true))

        vpnActivity.vpnReason = "fresh-connect"
        assertEquals("fresh-connect", vpnActivity.takeVpnReason(granted = true))
    }

    @Test
    fun rotationPreservesThePendingAttemptWithoutCancellingIt() {
        val cancellation = PermissionStartCancellation("test-process")
        val original = PendingPermissionStarts(cancellation).apply { vpnReason = "connect" }
        val restored = PendingPermissionStarts(cancellation)

        restored.restore(original.vpnReason, original.notificationReason, original.generationToken)

        assertEquals("connect", restored.takeVpnReason(granted = true))
    }

    @Test
    fun serviceStopAfterInstanceStateWasSavedStillInvalidatesTheRestoredAttempt() {
        val cancellation = PermissionStartCancellation("test-process")
        val original = PendingPermissionStarts(cancellation).apply { vpnReason = "connect" }
        val savedReason = original.vpnReason
        val savedToken = original.generationToken
        cancellation.cancel()

        val restored = PendingPermissionStarts(cancellation)
        restored.restore(savedReason, null, savedToken)

        assertNull(restored.takeVpnReason(granted = true))
    }

    @Test
    fun aNewProcessCannotReviveAnOldSavedPermissionAttemptAtTheSameGeneration() {
        val original = PendingPermissionStarts(PermissionStartCancellation("old-process"))
            .apply { notificationReason = "connect" }
        val restored = PendingPermissionStarts(PermissionStartCancellation("new-process"))

        restored.restore(null, original.notificationReason, original.generationToken)

        assertNull(restored.takeNotificationReason())
        restored.notificationReason = "new-connect"
        assertEquals("new-connect", restored.takeNotificationReason())
    }
}
