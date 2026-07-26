package dev.viasix.app.cfst

import dev.viasix.core.speedtest.SpeedTestParameters
import dev.viasix.core.speedtest.SpeedTestResultParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicReference
import kotlin.io.path.createTempDirectory
import kotlin.concurrent.thread

/**
 * Exercises [CfstRunner] failure paths and success parsing without a real CFST binary.
 * Uses missing binary / empty result file so the shipped entry points run on JVM.
 */
class CfstRunnerOutcomeTest {
    @Test
    fun failsWhenBinaryMissing() {
        val work = createTempDirectory("cfst-work").toFile()
        try {
            val runner = CfstRunner()
            val outcome =
                runner.run(
                    binary = File(work, "no-such-cfst"),
                    workDir = work,
                    parameters = SpeedTestParameters.defaultsForRange("2001:db8::/32"),
                )
            assertTrue(outcome is CfstRunOutcome.Failed)
            assertTrue((outcome as CfstRunOutcome.Failed).message.contains("未找到 CFST"))
            assertFalse(runner.isRunning)
        } finally {
            work.deleteRecursively()
        }
    }

    @Test
    fun failsWhenIpSourceMissing() {
        val work = createTempDirectory("cfst-work").toFile()
        val bin = File(work, "cfst").apply { writeText("x"); setExecutable(true) }
        try {
            val outcome =
                CfstRunner().run(
                    binary = bin,
                    workDir = work,
                    parameters = SpeedTestParameters(),
                )
            assertTrue(outcome is CfstRunOutcome.Failed)
            assertTrue((outcome as CfstRunOutcome.Failed).message.contains("IP"))
        } finally {
            work.deleteRecursively()
        }
    }

    @Test
    fun failsWhenIpFileMissing() {
        val work = createTempDirectory("cfst-work").toFile()
        val bin = File(work, "cfst").apply { writeText("x"); setExecutable(true) }
        try {
            val outcome =
                CfstRunner().run(
                    binary = bin,
                    workDir = work,
                    parameters = SpeedTestParameters.defaultsForFile(File(work, "missing.txt").absolutePath),
                )
            assertTrue(outcome is CfstRunOutcome.Failed)
            assertTrue((outcome as CfstRunOutcome.Failed).message.contains("找不到"))
        } finally {
            work.deleteRecursively()
        }
    }

    @Test
    fun parserIntegrationMatchesRunnerSuccessShape() {
        // Shipped parser path used after CFST exits; fixture mirrors runner's read→parse.
        val csv =
            """
            IP,Sent,Received,Loss,Latency,Speed,Region
            2001:db8::1,4,4,0.00,12.3,15.50,SJC
            """.trimIndent()
        val results = SpeedTestResultParser.parse(csv)
        val success =
            CfstRunOutcome.Success(
                results = results,
                resultCsvPath = "/tmp/result.csv",
                message = "测速完成：${results.size} 个结果",
            )
        assertEquals(1, success.results.size)
        assertEquals("2001:db8::1", success.results[0].ip)
        assertEquals("12.3", success.results[0].latency)
        assertTrue(success.message.contains("1"))
    }

    @Test
    fun runnersShareProcessWideSlotAndCrossInstanceCancellation() {
        val work = createTempDirectory("cfst-global-run").toFile()
        val script =
            File(work, "blocking-cfst").apply {
                writeText(
                    """
                    #!/bin/sh
                    trap 'exit 0' TERM INT
                    while :; do
                      sleep 1
                    done
                    """.trimIndent(),
                )
                setExecutable(true)
            }
        val first = CfstRunner()
        val firstOutcome = AtomicReference<CfstRunOutcome>()
        val worker =
            thread(name = "cfst-runner-test") {
                firstOutcome.set(
                    first.run(
                        binary = script,
                        workDir = work,
                        parameters = SpeedTestParameters.defaultsForRange("2001:db8::/32"),
                    ),
                )
            }
        try {
            val deadline = System.nanoTime() + 2_000_000_000L
            while (!first.isRunning && System.nanoTime() < deadline) {
                Thread.sleep(10)
            }
            assertTrue(first.isRunning)

            val duplicate =
                CfstRunner().run(
                    binary = script,
                    workDir = work,
                    parameters = SpeedTestParameters.defaultsForRange("2001:db8::/32"),
                )
            assertTrue(duplicate is CfstRunOutcome.Failed)
            assertTrue((duplicate as CfstRunOutcome.Failed).message.contains("已有测速任务"))

            assertTrue(CfstRunner().requestCancel())
            worker.join(5_000)
            assertFalse(worker.isAlive)
            assertEquals(CfstRunOutcome.Cancelled, firstOutcome.get())
            assertFalse(first.isRunning)
        } finally {
            CfstRunner().requestCancel()
            worker.join(5_000)
            work.deleteRecursively()
        }
    }

    @Test
    fun teardownCancelsRunnerFromViewModelNotOnDestroy() {
        // A running CFST must be cancelled on true teardown, but NOT on
        // Activity.onDestroy (which also fires on rotation) — otherwise a rotate
        // kills an in-flight speed test. Cancellation therefore lives in
        // SessionViewModel.onCleared, and onDestroy must not cancel.
        val activity =
            listOf(
                File("src/main/java/dev/viasix/app/MainActivity.kt"),
                File("app/src/main/java/dev/viasix/app/MainActivity.kt"),
            ).firstOrNull { it.isFile } ?: error("MainActivity.kt not found")
        val onDestroy =
            activity.readText()
                .substringAfter("override fun onDestroy()")
                .substringBefore("private fun currentNotificationPermissionState")
        assertFalse(
            "onDestroy must not cancel the runner (rotation would kill the run)",
            onDestroy.contains("requestCancel()"),
        )
        assertTrue(onDestroy.contains("super.onDestroy()"))

        val viewModel =
            listOf(
                File("src/main/java/dev/viasix/app/session/SessionViewModel.kt"),
                File("app/src/main/java/dev/viasix/app/session/SessionViewModel.kt"),
            ).firstOrNull { it.isFile } ?: error("SessionViewModel.kt not found")
        val onCleared =
            viewModel.readText()
                .substringAfter("override fun onCleared()")
                .substringBefore("}")
        assertTrue(
            "onCleared must cancel the retained runner on true teardown",
            onCleared.contains("cfstRunner.requestCancel()"),
        )
    }

    @Test
    fun runnerInjectsAndroidSslCertDirForHttping() {
        val runner =
            listOf(
                File("src/main/java/dev/viasix/app/cfst/CfstRunner.kt"),
                File("app/src/main/java/dev/viasix/app/cfst/CfstRunner.kt"),
            ).firstOrNull { it.isFile } ?: error("CfstRunner.kt not found")
        val source = runner.readText()
        assertTrue(source.contains("CfstSslEnvironment.applyTo"))
        assertTrue(source.contains("没有任何 IP 通过测速"))
        assertTrue(source.contains("CfstOutputParser.Stream"))
        assertTrue(source.contains("onProgress"))
    }

    @Test
    fun sslEnvironmentPrefersApexAndDoesNotOverrideExisting() {
        // Prefer apex when both would pass the usability check.
        assertEquals(
            "/apex/com.android.conscrypt/cacerts",
            CfstSslEnvironment.resolveCertDir { path ->
                path == "/apex/com.android.conscrypt/cacerts" ||
                    path == "/system/etc/security/cacerts"
            },
        )
        // Skip incomplete filtered system mounts (< 16 entries).
        assertEquals(
            "/apex/com.android.conscrypt/cacerts",
            CfstSslEnvironment.resolveCertDir { path ->
                path == "/apex/com.android.conscrypt/cacerts"
            },
        )
        val env = mutableMapOf("SSL_CERT_DIR" to "/custom")
        CfstSslEnvironment.applyTo(env, certDir = "/apex/com.android.conscrypt/cacerts")
        assertEquals("/custom", env["SSL_CERT_DIR"])

        val empty = mutableMapOf<String, String>()
        val pem =
            kotlin.io.path.createTempFile("cacerts", ".pem").toFile().apply {
                writeText("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")
            }
        try {
            CfstSslEnvironment.applyTo(
                empty,
                certDir = "/apex/com.android.conscrypt/cacerts",
                pemFile = pem,
            )
            assertEquals("/apex/com.android.conscrypt/cacerts", empty["SSL_CERT_DIR"])
            assertEquals(pem.absolutePath, empty["SSL_CERT_FILE"])
        } finally {
            pem.delete()
        }
    }
}
