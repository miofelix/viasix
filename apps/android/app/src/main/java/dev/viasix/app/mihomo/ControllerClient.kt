package dev.viasix.app.mihomo

import dev.viasix.core.formatting.ByteRateFormatter
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit

data class ControllerHealth(
    val ok: Boolean,
    val message: String,
    val version: String? = null,
)

data class TrafficTotals(
    val live: Boolean,
    val message: String,
    val uploadTotal: Long = 0,
    val downloadTotal: Long = 0,
    val connectionCount: Int = 0,
    /** Session memory from `/connections` (mihomo); 0 when the field is absent. */
    val memoryInUse: Long = 0,
)

/** Full UI snapshot: rates (derived), totals, optional memory. */
data class TrafficSnapshot(
    val live: Boolean = false,
    val upBps: Long = 0,
    val downBps: Long = 0,
    val uploadTotal: Long = 0,
    val downloadTotal: Long = 0,
    val memoryInUse: Long = 0,
    val connectionCount: Int = 0,
    val message: String = "—",
    val history: List<SpeedPoint> = emptyList(),
) {
    companion object {
        val Idle = TrafficSnapshot()
    }
}

data class SpeedPoint(
    val upBps: Long,
    val downBps: Long,
    val atMillis: Long = System.currentTimeMillis(),
)

data class ProxyDelayResult(
    val ok: Boolean,
    val delayMs: Int? = null,
    val message: String,
)

data class RoutingModeUpdate(
    val ok: Boolean,
    val restartRequired: Boolean = false,
)

/**
 * Mihomo external-controller HTTP client: health, traffic totals/rates, memory,
 * mode patch, and proxy delay tests.
 */
object ControllerClient {
    fun probe(host: String, port: Int, secret: String, timeoutMs: Int = 3000): ControllerHealth {
        return try {
            val conn = open("http://$host:$port/version", secret, timeoutMs)
            val code = conn.responseCode
            val body = readBody(conn)
            if (code !in 200..299) {
                ControllerHealth(false, "HTTP $code")
            } else {
                val version =
                    runCatching { JSONObject(body).optString("version").ifBlank { null } }
                        .getOrNull()
                ControllerHealth(
                    ok = true,
                    message = version?.let { "controller ok (version $it)" } ?: "controller ok",
                    version = version,
                )
            }
        } catch (error: Exception) {
            ControllerHealth(false, "unreachable: ${error.message}")
        }
    }

    fun connectionsTotals(
        host: String,
        port: Int,
        secret: String,
        timeoutMs: Int = 3000,
    ): TrafficTotals {
        return try {
            val conn = open("http://$host:$port/connections", secret, timeoutMs)
            val code = conn.responseCode
            val body = readBody(conn)
            if (code !in 200..299) {
                return TrafficTotals(false, "HTTP $code")
            }
            parseConnectionsTotalsBody(body)
        } catch (error: Exception) {
            TrafficTotals(false, "traffic unavailable: ${error.message}")
        }
    }

    /**
     * Parse a finite `/connections` JSON body (upload/download totals, connection count,
     * optional memory). Mihomo's dedicated `/memory` and `/traffic` endpoints are **chunked
     * streams** that never close; never use [readBody] on them or the UI poll will hang.
     *
     * Pure string parsing so JVM unit tests do not need Android's stubbed [JSONObject].
     */
    fun parseConnectionsTotalsBody(body: String): TrafficTotals {
        val up = longField(body, "uploadTotal")
        val down = longField(body, "downloadTotal")
        val memory = longField(body, "memory").coerceAtLeast(0)
        val count = topLevelArrayLength(body, "connections")
        return TrafficTotals(
            live = true,
            message =
                "Σ ↑ ${ByteRateFormatter.formatBytes(up)}  ↓ ${ByteRateFormatter.formatBytes(down)}",
            uploadTotal = up,
            downloadTotal = down,
            connectionCount = count,
            memoryInUse = memory,
        )
    }

    /** Top-level JSON number field (int/long). Nested objects are ignored by the regex. */
    internal fun longField(json: String, key: String): Long {
        val pattern = Regex("\"${Regex.escape(key)}\"\\s*:\\s*(-?\\d+)")
        return pattern.find(json)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
    }

    /**
     * Length of a top-level JSON array field. Counts root-ish `{`/`[` nesting so nested
     * objects inside array elements do not terminate the scan early.
     */
    internal fun topLevelArrayLength(json: String, key: String): Int {
        val keyPattern = Regex("\"${Regex.escape(key)}\"\\s*:\\s*\\[")
        val match = keyPattern.find(json) ?: return 0
        var i = match.range.last + 1
        var depth = 1
        var elements = 0
        var inString = false
        var escape = false
        var expectingValue = true
        while (i < json.length && depth > 0) {
            val c = json[i]
            when {
                escape -> escape = false
                inString && c == '\\' -> escape = true
                c == '"' -> inString = !inString
                inString -> Unit
                c == '{' || c == '[' -> {
                    if (depth == 1 && expectingValue) {
                        elements += 1
                        expectingValue = false
                    }
                    depth += 1
                }
                c == '}' || c == ']' -> {
                    depth -= 1
                }
                depth == 1 && c == ',' -> {
                    expectingValue = true
                }
                depth == 1 && expectingValue && !c.isWhitespace() && c != ']' -> {
                    // primitive element (number/bool/null/string already handled via quotes)
                    elements += 1
                    expectingValue = false
                }
            }
            i += 1
        }
        return elements.coerceAtLeast(0)
    }

    fun patchMode(
        host: String,
        port: Int,
        secret: String,
        mode: String,
        timeoutMs: Int = 3000,
    ): Boolean {
        return try {
            val conn = open("http://$host:$port/configs", secret, timeoutMs, method = "PATCH")
            try {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.outputStream.use { out ->
                    out.write("""{"mode":"$mode"}""".toByteArray(StandardCharsets.UTF_8))
                }
                conn.responseCode in 200..299
            } finally {
                conn.disconnect()
            }
        } catch (_: Exception) {
            false
        }
    }

    /**
     * A successful PATCH only changes mihomo's mode; it does not install missing
     * proxies/rules or select the managed node in the built-in GLOBAL selector.
     */
    fun updateRoutingMode(
        host: String,
        port: Int,
        secret: String,
        mode: String,
        timeoutMs: Int = 3000,
    ): RoutingModeUpdate =
        try {
            require(mode in setOf("direct", "rule", "global"))
            if (mode != "direct") {
                val global = readJson("http://$host:$port/proxies/GLOBAL", secret, timeoutMs)
                val candidates = global.getJSONArray("all")
                // Android's projection contains exactly one managed proxy.
                val managed = (0 until candidates.length())
                    .map { candidates.getString(it) }
                    .filter { it != "DIRECT" && it != "REJECT" }
                    .singleOrNull()
                if (managed == null) {
                    RoutingModeUpdate(ok = false, restartRequired = true)
                } else if (mode == "rule" && !hasManagedRules(host, port, secret, managed, timeoutMs)) {
                    RoutingModeUpdate(ok = false, restartRequired = true)
                } else if (mode == "global" && !selectGlobalProxy(host, port, secret, managed, timeoutMs)) {
                    RoutingModeUpdate(ok = false)
                } else {
                    RoutingModeUpdate(ok = patchMode(host, port, secret, mode, timeoutMs))
                }
            } else {
                RoutingModeUpdate(ok = patchMode(host, port, secret, mode, timeoutMs))
            }
        } catch (_: Exception) {
            RoutingModeUpdate(ok = false)
        }

    private fun hasManagedRules(
        host: String,
        port: Int,
        secret: String,
        managed: String,
        timeoutMs: Int,
    ): Boolean {
        val rules = readJson("http://$host:$port/rules", secret, timeoutMs).getJSONArray("rules")
        return (0 until rules.length()).any { rules.getJSONObject(it).optString("proxy") == managed }
    }

    private fun selectGlobalProxy(
        host: String,
        port: Int,
        secret: String,
        managed: String,
        timeoutMs: Int,
    ): Boolean {
        val path = "http://$host:$port/proxies/GLOBAL"
        val conn = open(path, secret, timeoutMs, method = "PUT")
        try {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { out ->
                out.write(JSONObject().put("name", managed).toString().toByteArray(StandardCharsets.UTF_8))
            }
            if (conn.responseCode !in 200..299) return false
        } finally {
            conn.disconnect()
        }
        return readJson(path, secret, timeoutMs).optString("now") == managed
    }

    private fun readJson(url: String, secret: String, timeoutMs: Int): JSONObject {
        val conn = open(url, secret, timeoutMs)
        try {
            check(conn.responseCode in 200..299) { "Controller HTTP ${conn.responseCode}" }
            return JSONObject(readBody(conn))
        } finally {
            conn.disconnect()
        }
    }

    /**
     * Proxy delay against a URL (Clash/Mihomo `/proxies/{name}/delay`).
     */
    fun proxyDelay(
        host: String,
        port: Int,
        secret: String,
        proxyName: String,
        testUrl: String = "https://www.gstatic.com/generate_204",
        timeoutMs: Int = 5000,
    ): ProxyDelayResult {
        return try {
            val encoded =
                URLEncoder.encode(proxyName, StandardCharsets.UTF_8.name())
                    .replace("+", "%20")
            val urlEncoded =
                URLEncoder.encode(testUrl, StandardCharsets.UTF_8.name())
            val path =
                "http://$host:$port/proxies/$encoded/delay?url=$urlEncoded&timeout=$timeoutMs"
            val conn = open(path, secret, timeoutMs + 1000)
            val code = conn.responseCode
            val body = readBody(conn)
            if (code !in 200..299) {
                return ProxyDelayResult(false, message = "HTTP $code")
            }
            val delay = JSONObject(body).optInt("delay", -1)
            if (delay < 0) {
                ProxyDelayResult(false, message = "no delay field")
            } else {
                ProxyDelayResult(true, delayMs = delay, message = "${delay} ms")
            }
        } catch (error: Exception) {
            ProxyDelayResult(false, message = error.message ?: "delay failed")
        }
    }

    fun open(
        url: String,
        secret: String,
        timeoutMs: Int,
        method: String = "GET",
    ): HttpURLConnection {
        val conn = (URL(url).openConnection() as HttpURLConnection)
        conn.connectTimeout = timeoutMs
        conn.readTimeout = timeoutMs
        conn.requestMethod = method
        if (secret.isNotBlank()) {
            conn.setRequestProperty("Authorization", "Bearer $secret")
        }
        return conn
    }

    fun readBody(conn: HttpURLConnection): String {
        val stream =
            try {
                conn.inputStream
            } catch (_: Exception) {
                conn.errorStream
            } ?: return ""
        return stream.bufferedReader().use { it.readText() }
    }

    @Deprecated("Use ByteRateFormatter", ReplaceWith("ByteRateFormatter.formatBytes(bytes)"))
    fun formatBytes(bytes: Long): String = ByteRateFormatter.formatBytes(bytes)

    fun sleepQuietly(ms: Long) {
        try {
            TimeUnit.MILLISECONDS.sleep(ms)
        } catch (_: InterruptedException) {
        }
    }
}

/**
 * Derives instantaneous rates from successive `/connections` totals
 * (same approach as the Windows traffic sampler).
 */
class TrafficSampler(
    private val maxHistory: Int = 120,
) {
    private var lastUpload: Long? = null
    private var lastDownload: Long? = null
    private var lastAtMillis: Long? = null
    private val points = ArrayDeque<SpeedPoint>()

    fun reset() {
        lastUpload = null
        lastDownload = null
        lastAtMillis = null
        points.clear()
    }

    fun sample(host: String, port: Int, secret: String): TrafficSnapshot {
        val totals = ControllerClient.connectionsTotals(host, port, secret)
        if (!totals.live) {
            return TrafficSnapshot(
                live = false,
                upBps = 0,
                downBps = 0,
                uploadTotal = lastUpload ?: 0,
                downloadTotal = lastDownload ?: 0,
                memoryInUse = 0,
                connectionCount = 0,
                message = totals.message,
                history = points.toList(),
            )
        }

        val now = System.currentTimeMillis()
        val (upBps, downBps) =
            when {
                lastUpload != null && lastDownload != null && lastAtMillis != null -> {
                    val secs = ((now - lastAtMillis!!) / 1000.0).coerceAtLeast(0.001)
                    val up = ((totals.uploadTotal - lastUpload!!).coerceAtLeast(0) / secs).toLong()
                    val down =
                        ((totals.downloadTotal - lastDownload!!).coerceAtLeast(0) / secs).toLong()
                    up to down
                }
                else -> 0L to 0L
            }
        lastUpload = totals.uploadTotal
        lastDownload = totals.downloadTotal
        lastAtMillis = now

        points.addLast(SpeedPoint(upBps, downBps, now))
        while (points.size > maxHistory) points.removeFirst()

        // Memory comes from the finite /connections snapshot — do not call streaming /memory.
        return TrafficSnapshot(
            live = true,
            upBps = upBps,
            downBps = downBps,
            uploadTotal = totals.uploadTotal,
            downloadTotal = totals.downloadTotal,
            memoryInUse = totals.memoryInUse,
            connectionCount = totals.connectionCount,
            message =
                "↑ ${ByteRateFormatter.formatRate(upBps)}  ↓ ${ByteRateFormatter.formatRate(downBps)}" +
                    "  ·  Σ ↑ ${ByteRateFormatter.formatBytes(totals.uploadTotal)}" +
                    "  ↓ ${ByteRateFormatter.formatBytes(totals.downloadTotal)}",
            history = points.toList(),
        )
    }
}
