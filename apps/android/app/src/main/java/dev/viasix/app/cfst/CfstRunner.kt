package dev.viasix.app.cfst

import android.util.Log
import dev.viasix.core.speedtest.CfstOutputParser
import dev.viasix.core.speedtest.SpeedTestParameters
import dev.viasix.core.speedtest.SpeedTestResult
import dev.viasix.core.speedtest.SpeedTestResultParser
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * One-at-a-time cancellable CFST process runner.
 * Mirrors macOS [CfstRunner] lifecycle: spawn → poll → parse result.csv → reap.
 *
 * @param onProgress invoked from the process reader thread when CFST bar progress changes
 *   (`current / total`). Callers that update Compose state must hop to the main thread.
 */
class CfstRunner {
    private val processRef = AtomicReference<Process?>(null)
    private val cancelRequested = AtomicBoolean(false)

    val isRunning: Boolean
        get() = activeRunner.get() != null

    /**
     * Request cancel. Returns true if a run was in flight.
     */
    fun requestCancel(): Boolean {
        val owner = activeRunner.get() ?: return false
        owner.cancelRequested.set(true)
        owner.processRef.get()?.let { process ->
            try {
                process.destroy()
            } catch (_: Exception) {
            }
        }
        return true
    }

    fun run(
        binary: File,
        workDir: File,
        parameters: SpeedTestParameters,
        onProgress: ((current: Int, total: Int, phaseHint: String?) -> Unit)? = null,
        /** Optional Android context so HTTPing can load the system CA store. */
        sslContext: android.content.Context? = null,
        /** Includes cancellation requested while the caller was preparing the binary/list. */
        isCancellationRequested: () -> Boolean = { false },
    ): CfstRunOutcome {
        if (!activeRunner.compareAndSet(null, this)) {
            return CfstRunOutcome.Failed("已有测速任务正在运行")
        }
        cancelRequested.set(false)
        return try {
            if (isCancellationRequested()) {
                CfstRunOutcome.Cancelled
            } else {
                runInner(binary, workDir, parameters, onProgress, sslContext, isCancellationRequested)
            }
        } finally {
            processRef.set(null)
            activeRunner.compareAndSet(this, null)
            cancelRequested.set(false)
        }
    }

    private fun runInner(
        binary: File,
        workDir: File,
        parameters: SpeedTestParameters,
        onProgress: ((current: Int, total: Int, phaseHint: String?) -> Unit)?,
        sslContext: android.content.Context?,
        isCancellationRequested: () -> Boolean,
    ): CfstRunOutcome {
        if (!binary.isFile) {
            return CfstRunOutcome.Failed(
                "未找到 CFST：${binary.absolutePath}。运行 node apps/android/scripts/fetch-cfst.mjs",
            )
        }
        if (!parameters.hasIpSource()) {
            return CfstRunOutcome.Failed("请填写 IP 段或选择内置 IPv6 列表")
        }

        val range = parameters.ipRange.trim()
        if (range.isEmpty()) {
            val file = File(parameters.ipFile.trim())
            if (!file.isFile || file.length() == 0L) {
                return CfstRunOutcome.Failed("找不到 IP 地址文件：${parameters.ipFile}")
            }
        }

        if (!workDir.exists() && !workDir.mkdirs()) {
            return CfstRunOutcome.Failed("无法创建工作目录：${workDir.absolutePath}")
        }

        val resultPath = File(workDir, "result.csv")
        if (resultPath.exists()) {
            resultPath.delete()
        }

        val args =
            try {
                parameters.commandLineArguments(resultPath.absolutePath)
            } catch (error: IllegalArgumentException) {
                return CfstRunOutcome.Failed(error.message ?: "参数无效")
            }

        val command = listOf(binary.absolutePath) + args
        if (cancelRequested.get() || isCancellationRequested()) return CfstRunOutcome.Cancelled
        logInfo("spawn CFST: ${command.joinToString(" ")}")

        val process =
            try {
                val builder =
                    ProcessBuilder(command)
                        .directory(workDir)
                        .redirectErrorStream(true)
                // Go's x509 does not use the Android system trust store by default.
                // Without this, HTTPing fails with "certificate signed by unknown authority"
                // and CFST exits 0 without writing result.csv (0 available IPs).
                if (sslContext != null) {
                    CfstSslEnvironment.applyForContext(sslContext, builder.environment())
                } else {
                    CfstSslEnvironment.applyTo(builder.environment())
                }
                builder.start()
            } catch (error: Exception) {
                return CfstRunOutcome.Failed("无法启动 CFST：${error.message}")
            }
        processRef.set(process)

        // CFST redraws progress with `\r` (no newline). Read chunks and parse live bars.
        val outputParser = CfstOutputParser.Stream()
        val logThread =
            Thread(
                {
                    try {
                        process.inputStream.bufferedReader().use { reader ->
                            val buf = CharArray(1_024)
                            while (true) {
                                val n = reader.read(buf)
                                if (n < 0) break
                                if (n == 0) continue
                                val chunk = String(buf, 0, n)
                                val progress = outputParser.consume(chunk)
                                if (progress != null) {
                                    onProgress?.invoke(
                                        progress.current,
                                        progress.total,
                                        outputParser.lastPhaseHint(),
                                    )
                                }
                                // Log only newline-delimited slices to avoid flooding logcat
                                // with partial progress redraws.
                                chunk.split('\n', '\r').forEach { line ->
                                    val clean =
                                        CfstOutputParser.stripAnsi(line)
                                            .trim()
                                    if (clean.isNotEmpty() &&
                                        !clean.contains('[') &&
                                        clean.length < 400
                                    ) {
                                        logInfo(clean)
                                    }
                                }
                            }
                            outputParser.finish()?.let { progress ->
                                onProgress?.invoke(
                                    progress.current,
                                    progress.total,
                                    outputParser.lastPhaseHint(),
                                )
                            }
                        }
                    } catch (_: Exception) {
                    }
                },
                "cfst-log",
            )
        logThread.isDaemon = true
        logThread.start()

        while (true) {
            if (cancelRequested.get() || isCancellationRequested()) {
                terminateProcess(process)
                try {
                    logThread.join(1_000)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                return CfstRunOutcome.Cancelled
            }
            try {
                val exited = process.waitFor(120, TimeUnit.MILLISECONDS)
                if (exited) break
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                process.destroyForcibly()
                try {
                    logThread.join(1_000)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                return CfstRunOutcome.Cancelled
            }
        }

        try {
            logThread.join(2_000)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }

        if (cancelRequested.get() || isCancellationRequested()) {
            return CfstRunOutcome.Cancelled
        }

        val exit = process.exitValue()
        if (exit != 0) {
            return CfstRunOutcome.Failed("CFST 异常退出（状态码 $exit）")
        }

        // When every IP fails latency filtering (common with broken TLS trust for HTTPing),
        // CFST often exits 0 without creating -o result.csv.
        if (!resultPath.isFile) {
            return CfstRunOutcome.Failed(
                "没有任何 IP 通过测速。若正在使用 HTTPing，请确认系统证书可用，或在测速设置中改用 TCPing",
            )
        }

        val csv =
            try {
                resultPath.readText()
            } catch (error: IOException) {
                return CfstRunOutcome.Failed("读取测速结果失败：${error.message}")
            }

        val results = SpeedTestResultParser.parse(csv)
        if (results.isEmpty()) {
            return CfstRunOutcome.Failed("没有任何 IP 通过测速")
        }

        return CfstRunOutcome.Success(
            results = results,
            resultCsvPath = resultPath.absolutePath,
            message = "测速完成：${results.size} 个结果",
        )
    }

    private fun terminateProcess(process: Process) {
        try {
            process.destroy()
            if (!process.waitFor(2, TimeUnit.SECONDS)) {
                process.destroyForcibly()
                process.waitFor(1, TimeUnit.SECONDS)
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            process.destroyForcibly()
        } catch (_: Exception) {
            process.destroyForcibly()
        }
    }

    private fun logInfo(message: String) {
        try {
            Log.i(TAG, message)
        } catch (_: RuntimeException) {
            // android.util.Log is unavailable in local JVM unit tests.
        }
    }

    companion object {
        private const val TAG = "CfstRunner"
        private val activeRunner = AtomicReference<CfstRunner?>(null)
    }
}

sealed class CfstRunOutcome {
    data class Success(
        val results: List<SpeedTestResult>,
        val resultCsvPath: String,
        val message: String,
    ) : CfstRunOutcome()

    data object Cancelled : CfstRunOutcome()

    data class Failed(val message: String) : CfstRunOutcome()
}
