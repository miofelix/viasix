package dev.viasix.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import dev.viasix.app.prefs.DefaultProfile
import dev.viasix.app.prefs.SessionPrefs
import dev.viasix.app.prefs.SessionPrefsStore
import dev.viasix.app.ui.AppSection
import dev.viasix.core.speedtest.SpeedTestParameters
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Actual accessibility/UI interactions; these tests never start a public-network speed test. */
@RunWith(AndroidJUnit4::class)
class AndroidUiDeviceTest : IsolatedVpnDeviceTest() {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private var activity: MainActivity? = null

    @Before
    fun launchFreshUi() {
        SessionPrefsStore(context).save(SessionPrefs())
        launchActivity()
        assertTrue(device.wait(Until.hasObject(By.text(AppSection.OVERVIEW.subtitle)), 8_000))
    }

    // JUnit runs subclass @After methods before the superclass restores saved prefs.
    @After
    fun closeUiBeforeRestoringPreferences() {
        closeActivity()
    }

    @Test
    fun allFiveNavigationDestinationsOpenAndLastSectionSurvivesRelaunch() {
        AppSection.entries.forEach(::navigate)
        assertEquals("settings", SessionPrefsStore(context).load().selectedSection)
        closeActivity()
        launchActivity()
        assertTrue("Last navigation destination was not restored", device.wait(Until.hasObject(By.text(AppSection.SETTINGS.subtitle)), 8_000))
    }

    @Test
    fun invalidYamlDraftNeverReplacesTheBundledAppliedProfile() {
        navigate(AppSection.PROFILES)
        val invalidDraft = "proxies: ["
        replaceText(editorForLabel("Profile YAML"), invalidDraft)
        awaitCondition("YAML input did not update the draft", 5_000) {
            SessionPrefsStore(context).load().profileDraft == invalidDraft
        }
        assertEquals(DefaultProfile.yaml, SessionPrefsStore(context).load().profileYaml)
    }

    @Test
    fun invalidNumericEditDoesNotOverwriteTheSavedSpeedParameter() {
        navigate(AppSection.NODES)
        scrollToText("测速设置（模式 · 筛选 · 性能）").click()
        replaceText(editorForLabel("测速端口"), "8443")
        awaitCondition("Valid numeric edit did not update the speed parameters", 5_000) {
            SessionPrefsStore(context).load().speedParameters.port == 8443
        }
        replaceText(editorForLabel("测速端口"), "abc")
        assertEquals("abc", editorForLabel("测速端口").text)
        assertEquals(8443, SessionPrefsStore(context).load().speedParameters.port)
    }

    @Test
    fun mtuSettingPersistsAcrossNavigationAndActivityRecreation() {
        navigate(AppSection.SETTINGS)
        replaceText(editorForLabel("VPN MTU"), "1280")
        awaitCondition("MTU field did not persist its value", 5_000) {
            SessionPrefsStore(context).load().vpnMtu == "1280"
        }
        closeActivity()
        launchActivity()
        assertTrue(device.wait(Until.hasObject(By.text(AppSection.SETTINGS.subtitle)), 8_000))
        assertEquals("Activity recreation discarded the MTU setting", "1280", editorForLabel("VPN MTU").text)
    }

    private fun launchActivity() {
        activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        ) as MainActivity
        instrumentation.waitForIdleSync()
    }

    private fun closeActivity() {
        activity?.let { current -> instrumentation.runOnMainSync { current.finish() } }
        activity = null
        instrumentation.waitForIdleSync()
    }

    private fun navigate(section: AppSection) {
        hideKeyboard()
        val index = AppSection.entries.indexOf(section)
        device.click(
            ((index + 0.5f) * device.displayWidth / AppSection.entries.size).toInt(),
            device.displayHeight - 300,
        )
        assertTrue("Page ${section.title} did not open", device.wait(Until.hasObject(By.text(section.subtitle)), 5_000))
        awaitCondition("Navigation did not persist ${section.wire}", 5_000) {
            SessionPrefsStore(context).load().selectedSection == section.wire
        }
    }

    private fun replaceText(editor: UiObject2, value: String) {
        editor.click()
        editor.text = value
        hideKeyboard()
        instrumentation.waitForIdleSync()
    }

    private fun hideKeyboard() {
        instrumentation.waitForIdleSync()
        // Let the keyboard requested by a field click finish opening before hiding it.
        // On this device the accessibility tree exposes controls behind the keyboard.
        device.waitForIdle(1_000)
        activity?.let { current ->
            instrumentation.runOnMainSync {
                val manager = current.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                val token = current.currentFocus?.windowToken ?: current.window.decorView.windowToken
                manager.hideSoftInputFromWindow(token, 0)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    current.window.insetsController?.hide(WindowInsets.Type.ime())
                }
            }
        }
        device.waitForIdle(1_000)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            awaitCondition("Keyboard did not close before the next UI interaction", 5_000) {
                var visible = false
                instrumentation.runOnMainSync {
                    visible = activity?.window?.decorView?.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
                }
                !visible
            }
        }
    }

    /** TextField labels can be descendants or merged into the editable accessibility node. */
    private fun editorForLabel(label: String): UiObject2 {
        val labelNode = scrollToText(label)
        var ancestor: UiObject2? = labelNode
        repeat(5) {
            val node = ancestor ?: return@repeat
            if (node.className == "android.widget.EditText") return node
            node.findObject(By.clazz("android.widget.EditText"))?.let { return it }
            ancestor = node.parent
        }
        val bounds = labelNode.visibleBounds
        val editors = device.findObjects(By.clazz("android.widget.EditText"))
            .filter { !it.visibleBounds.isEmpty }
        return editors.firstOrNull { it.visibleBounds.contains(bounds.centerX(), bounds.centerY()) }
            ?: editors.singleOrNull()
            ?: throw AssertionError("No editable UI field was associated with label $label")
    }

    private fun scrollToText(label: String): UiObject2 {
        repeat(12) {
            val node = device.findObject(By.text(label)) ?: device.findObject(By.textContains(label))
            if (node != null && !node.visibleBounds.isEmpty) return node
            device.swipe(
                device.displayWidth / 2, device.displayHeight - 400,
                device.displayWidth / 2, 500,
                500,
            )
            settleUiAfterScroll()
        }
        throw AssertionError("UI text was not reachable by scrolling: $label")
    }

    private fun scrollToBeginning() {
        repeat(8) {
            device.swipe(
                device.displayWidth / 2, 500,
                device.displayWidth / 2, device.displayHeight - 400,
                500,
            )
            settleUiAfterScroll()
        }
    }

    private fun settleUiAfterScroll() {
        instrumentation.waitForIdleSync()
        device.waitForIdle(1_000)
    }

}
