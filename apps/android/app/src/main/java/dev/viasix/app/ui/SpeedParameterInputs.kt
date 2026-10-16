package dev.viasix.app.ui

import androidx.compose.runtime.mutableStateMapOf
import dev.viasix.core.speedtest.SpeedTestParameters

/** Numeric edits remain visible, including incomplete input, until corrected or reset. */
enum class SpeedNumericField {
    PORT,
    HTTPING_CODE,
    LATENCY_UPPER,
    LATENCY_LOWER,
    LOSS_UPPER,
    SPEED_LOWER,
    THREADS,
    PING_COUNT,
    DOWNLOAD_COUNT,
    DOWNLOAD_TIME,
    ;

    fun committedText(parameters: SpeedTestParameters): String =
        when (this) {
            PORT -> parameters.port.toString()
            HTTPING_CODE -> parameters.httpingCode.toString()
            LATENCY_UPPER -> parameters.latencyUpperBound.toString()
            LATENCY_LOWER -> parameters.latencyLowerBound.toString()
            LOSS_UPPER -> formatDecimalInput(parameters.lossRateUpperBound)
            SPEED_LOWER -> formatDecimalInput(parameters.speedLowerBound)
            THREADS -> parameters.threads.toString()
            PING_COUNT -> parameters.pingCount.toString()
            DOWNLOAD_COUNT -> parameters.downloadCount.toString()
            DOWNLOAD_TIME -> parameters.downloadTime.toString()
        }

    fun isUsed(parameters: SpeedTestParameters, currentNodeTest: Boolean): Boolean =
        when (this) {
            HTTPING_CODE -> parameters.httping
            DOWNLOAD_COUNT, DOWNLOAD_TIME -> !parameters.disableDownload
            SPEED_LOWER -> !parameters.disableDownload && !currentNodeTest
            LATENCY_UPPER, LATENCY_LOWER, LOSS_UPPER -> !currentNodeTest
            else -> true
        }
}

internal fun formatDecimalInput(value: Double): String =
    if (value.isFinite() && value == value.toLong().toDouble()) {
        value.toLong().toString()
    } else {
        value.toString()
    }

/** Retained with the session so navigation or rotation cannot hide an invalid edit. */
class SpeedParameterInputs {
    private data class Draft(val raw: String, val committedText: String, val valid: Boolean)

    private val drafts = mutableStateMapOf<SpeedNumericField, Draft>()

    fun text(field: SpeedNumericField, committedText: String): String =
        drafts[field]?.takeIf { it.committedText == committedText }?.raw ?: committedText

    fun edit(field: SpeedNumericField, raw: String, committedText: String, valid: Boolean) {
        drafts[field] = Draft(raw, committedText, valid)
    }

    fun validationMessage(
        parameters: SpeedTestParameters,
        currentNodeTest: Boolean = false,
    ): String? =
        if (drafts.any { (field, draft) ->
                !draft.valid &&
                    draft.committedText == field.committedText(parameters) &&
                    field.isUsed(parameters, currentNodeTest)
            }
        ) {
            "请展开测速设置并修正未完成的数字输入"
        } else {
            null
        }

    fun reset() {
        drafts.clear()
    }
}
