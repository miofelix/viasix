package dev.viasix.app.ui

import dev.viasix.core.speedtest.SpeedTestParameters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class SpeedParameterInputsTest {
    private val parameters = SpeedTestParameters.defaultsForRange()

    @Test
    fun incompleteNumberBlocksBothTestsUntilCorrected() {
        val inputs = SpeedParameterInputs()
        inputs.edit(SpeedNumericField.PORT, "", "443", valid = false)

        assertEquals("", inputs.text(SpeedNumericField.PORT, "443"))
        assertNotNull(inputs.validationMessage(parameters))
        assertNotNull(inputs.validationMessage(parameters, currentNodeTest = true))
        // Changing another setting cannot silently discard the incomplete edit.
        assertNotNull(inputs.validationMessage(parameters.copy(threads = 20)))

        inputs.edit(SpeedNumericField.PORT, "8443", "8443", valid = true)
        val corrected = parameters.copy(port = 8443)
        assertNull(inputs.validationMessage(corrected))
        assertNull(inputs.validationMessage(corrected, currentNodeTest = true))
    }

    @Test
    fun partialDecimalRemainsVisibleWithoutChangingItsNumericValue() {
        val inputs = SpeedParameterInputs()
        inputs.edit(SpeedNumericField.LOSS_UPPER, "0.", "0", valid = true)

        assertEquals("0.", inputs.text(SpeedNumericField.LOSS_UPPER, "0"))
        assertNull(inputs.validationMessage(parameters.copy(lossRateUpperBound = 0.0)))
    }

    @Test
    fun currentNodeTestOnlyIgnoresFiltersItOverrides() {
        val inputs = SpeedParameterInputs()
        inputs.edit(SpeedNumericField.LATENCY_UPPER, "", "9999", valid = false)
        assertNotNull(inputs.validationMessage(parameters))
        assertNull(inputs.validationMessage(parameters, currentNodeTest = true))

        inputs.edit(SpeedNumericField.THREADS, "9999999999999", "200", valid = false)
        assertNotNull(inputs.validationMessage(parameters, currentNodeTest = true))
    }

    @Test
    fun disabledControlsDoNotBlockTheActiveMode() {
        val inputs = SpeedParameterInputs()
        inputs.edit(SpeedNumericField.DOWNLOAD_TIME, "", "10", valid = false)
        assertNotNull(inputs.validationMessage(parameters))
        assertNull(inputs.validationMessage(parameters.copy(disableDownload = true)))

        inputs.edit(SpeedNumericField.HTTPING_CODE, "", "0", valid = false)
        assertNotNull(inputs.validationMessage(parameters.copy(disableDownload = true)))
        assertNull(inputs.validationMessage(parameters.copy(disableDownload = true, httping = false)))
    }

    @Test
    fun externalReplacementAndExplicitResetRestoreTheVisibleValue() {
        val inputs = SpeedParameterInputs()
        inputs.edit(SpeedNumericField.PORT, "", "443", valid = false)

        assertEquals("8443", inputs.text(SpeedNumericField.PORT, "8443"))
        assertNull(inputs.validationMessage(parameters.copy(port = 8443)))

        inputs.reset()
        assertEquals("443", inputs.text(SpeedNumericField.PORT, "443"))
        assertNull(inputs.validationMessage(parameters))
    }
}
