package dev.viasix.app.net

import java.net.HttpURLConnection
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.nio.charset.StandardCharsets

enum class ExitIPDetectionMode(val wire: String, val label: String) {
    /** Use the configured detection service, then try explicit address-family fallbacks. */
    AUTOMATIC("automatic", "自动"),
    IPV4("ipv4", "IPv4"),
    IPV6("ipv6", "IPv6");

    companion object {
        fun parse(raw: String?): ExitIPDetectionMode =
            entries.firstOrNull { it.wire == raw || it.name.equals(raw, ignoreCase = true) }
                ?: AUTOMATIC
    }
}

data class ExitIPInfo(
    val ip: String,
    val location: String = "",
    val details: String = "",
    val family: String = "",
    val route: ExitIPRoute = ExitIPRoute.DIRECT,
)

enum class ExitIPRoute(val label: String) {
    DIRECT("直连"),
    MIXED_PROXY("本地 mixed 代理"),
}

data class ExitIPProxy(
    val host: String,
    val port: Int,
) {
    init {
        require(host.isNotBlank()) { "proxy host is blank" }
        require(port in 1..65_535) { "invalid proxy port: $port" }
    }

    internal fun asJavaProxy(): Proxy =
        Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(host, port))
}

object ExitIPRoutePolicy {
    fun proxyForRuntime(
        running: Boolean,
        mixedPort: Int,
    ): ExitIPProxy? =
        if (running) ExitIPProxy(host = "127.0.0.1", port = mixedPort) else null

    fun routeFor(proxy: ExitIPProxy?): ExitIPRoute =
        if (proxy == null) ExitIPRoute.DIRECT else ExitIPRoute.MIXED_PROXY

    fun routeForRuntime(running: Boolean): ExitIPRoute =
        if (running) ExitIPRoute.MIXED_PROXY else ExitIPRoute.DIRECT
}

/** Injectable transport preserves the same route for every primary, fallback and geo request. */
fun interface ExitIPRequest {
    fun get(url: String, timeoutMs: Int, proxy: ExitIPProxy?): String
}

/**
 * Detects the outbound address independently of the proxy server's address family.
 * JSON parsing is intentionally dependency-light so unit tests run on the JVM
 * without Android's stubbed org.json.
 */
object ExitIPDetector {
    const val DEFAULT_ENDPOINT = "https://api.myip.la/cn?json"
    const val IPV4_ENDPOINT = "https://v4.ident.me"
    const val IPV4_FALLBACK_ENDPOINT = "https://checkip.amazonaws.com"
    const val IPV6_ENDPOINT = "https://v6.ident.me"
    const val GEO_ENDPOINT = "https://ipwho.is"
    private const val GEO_TIMEOUT_CAP_MS = 1500

    fun endpointFor(mode: ExitIPDetectionMode, automaticEndpoint: String): String =
        when (mode) {
            ExitIPDetectionMode.AUTOMATIC -> automaticEndpoint.trim().ifBlank { DEFAULT_ENDPOINT }
            ExitIPDetectionMode.IPV4 -> IPV4_ENDPOINT
            ExitIPDetectionMode.IPV6 -> IPV6_ENDPOINT
        }

    /**
     * Detection order for a user-selected mode.
     *
     * An IPv6 connection to a proxy does not imply an IPv6 outbound connection.
     * Automatic respects the configured endpoint, then tries IPv4 and IPv6 fallbacks.
     */
    fun detectionAttemptModes(mode: ExitIPDetectionMode): List<ExitIPDetectionMode> =
        when (mode) {
            ExitIPDetectionMode.AUTOMATIC ->
                listOf(
                    ExitIPDetectionMode.AUTOMATIC,
                    ExitIPDetectionMode.IPV4,
                    ExitIPDetectionMode.IPV6,
                )
            ExitIPDetectionMode.IPV4,
            ExitIPDetectionMode.IPV6,
            -> listOf(mode)
        }

    fun detect(
        mode: ExitIPDetectionMode = ExitIPDetectionMode.AUTOMATIC,
        automaticEndpoint: String = DEFAULT_ENDPOINT,
        timeoutMs: Int = 8000,
        enrich: Boolean = true,
        proxy: ExitIPProxy? = null,
        request: ExitIPRequest = ExitIPRequest(::httpGet),
    ): Result<ExitIPInfo> {
        require(timeoutMs > 0) { "timeout must be positive" }
        var lastError: Exception? = null
        for (attempt in detectionAttemptModes(mode)) {
            // At most five primary requests: custom/default, two IPv4 services, IPv6.
            val endpoints =
                when (attempt) {
                    ExitIPDetectionMode.AUTOMATIC ->
                        listOf(endpointFor(attempt, automaticEndpoint), DEFAULT_ENDPOINT).distinct()
                    ExitIPDetectionMode.IPV4 -> listOf(IPV4_ENDPOINT, IPV4_FALLBACK_ENDPOINT)
                    ExitIPDetectionMode.IPV6 -> listOf(IPV6_ENDPOINT)
                }
            for (endpoint in endpoints) {
                try {
                    val raw = request.get(endpoint, timeoutMs, proxy)
                    var info =
                        validateExpectedFamily(
                            mode = attempt,
                            info = parsePrimary(raw).copy(route = ExitIPRoutePolicy.routeFor(proxy)),
                        )
                    if (enrich && info.location.isBlank()) {
                        info = enrichWithGeo(info, minOf(timeoutMs, GEO_TIMEOUT_CAP_MS), proxy, request) ?: info
                    }
                    return Result.success(info)
                } catch (error: Exception) {
                    lastError = error
                }
            }
        }
        return Result.failure(
            IllegalStateException(
                "${mode.label}出口 IP 检测失败：${lastError?.message ?: "检测服务不可用"}",
                lastError,
            ),
        )
    }

    fun parsePrimary(body: String): ExitIPInfo {
        val trimmed = body.trim()
        if (trimmed.startsWith("{")) {
            val ip =
                stringField(trimmed, "ip")
                    ?: stringField(trimmed, "IP")
                    ?: stringField(trimmed, "query")
                    ?: stringField(trimmed, "origin")
                    ?: throw IllegalArgumentException("no ip field")
            val city =
                nestedStringField(trimmed, "location", "city")
                    ?: stringField(trimmed, "city")
            val country =
                nestedStringField(trimmed, "location", "country_name")
                    ?: stringField(trimmed, "country")
            val region = stringField(trimmed, "region")
            val location =
                listOfNotNull(city, region, country)
                    .filter { it.isNotBlank() }
                    .distinct()
                    .joinToString(" · ")
            val normalizedIp = normalizeIp(ip)
            return ExitIPInfo(
                ip = normalizedIp,
                location = location,
                family = addressFamily(normalizedIp),
            )
        }
        val ip = normalizeIp(trimmed.lineSequence().first().trim())
        return ExitIPInfo(ip = ip, family = addressFamily(ip))
    }

    internal fun validateExpectedFamily(
        mode: ExitIPDetectionMode,
        info: ExitIPInfo,
    ): ExitIPInfo {
        val expected =
            when (mode) {
                ExitIPDetectionMode.AUTOMATIC -> null
                ExitIPDetectionMode.IPV4 -> "IPv4"
                ExitIPDetectionMode.IPV6 -> "IPv6"
            }
        if (expected != null && info.family != expected) {
            throw IllegalArgumentException("出口 IP 服务未返回预期的 $expected 地址")
        }
        return info
    }

    private fun enrichWithGeo(
        info: ExitIPInfo,
        timeoutMs: Int,
        proxy: ExitIPProxy?,
        request: ExitIPRequest,
    ): ExitIPInfo? {
        return try {
            val url = "$GEO_ENDPOINT/${info.ip}?lang=zh-CN"
            val body = request.get(url, timeoutMs, proxy)
            if (body.contains("\"success\":false")) return null
            val location =
                listOfNotNull(
                    stringField(body, "country"),
                    stringField(body, "region"),
                    stringField(body, "city"),
                ).filter { it.isNotBlank() }.joinToString(" · ")
            val details =
                listOfNotNull(
                    nestedStringField(body, "connection", "isp"),
                    nestedStringField(body, "connection", "org"),
                    stringField(body, "isp"),
                    stringField(body, "org"),
                    stringField(body, "timezone"),
                ).filter { it.isNotBlank() }.distinct().joinToString(" · ")
            info.copy(
                location = location.ifBlank { info.location },
                details = details.ifBlank { info.details },
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun stringField(json: String, key: String): String? {
        val pattern = Regex("\"${Regex.escape(key)}\"\\s*:\\s*\"([^\"]*)\"")
        return pattern.find(json)?.groupValues?.get(1)?.takeIf { it.isNotBlank() }
    }

    private fun nestedStringField(json: String, parent: String, key: String): String? {
        val parentPattern =
            Regex("\"${Regex.escape(parent)}\"\\s*:\\s*\\{([^}]*)\\}")
        val block = parentPattern.find(json)?.groupValues?.get(1) ?: return null
        return stringField("{$block}", key)
    }

    private fun httpGet(
        url: String,
        timeoutMs: Int,
        proxy: ExitIPProxy?,
    ): String {
        val connection =
            if (proxy == null) {
                URL(url).openConnection()
            } else {
                URL(url).openConnection(proxy.asJavaProxy())
            }
        val conn = connection as? HttpURLConnection
            ?: throw IllegalArgumentException("unsupported URL protocol")
        try {
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            conn.requestMethod = "GET"
            conn.setRequestProperty("User-Agent", "ViaSix-Android/0.1")
            conn.setRequestProperty("Accept", "application/json,text/plain,*/*")
            val code = conn.responseCode
            val stream =
                try {
                    conn.inputStream
                } catch (_: Exception) {
                    conn.errorStream
                } ?: throw IllegalStateException("empty body")
            val body = stream.bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
            if (code !in 200..299) {
                throw IllegalStateException("HTTP $code")
            }
            return body
        } finally {
            conn.disconnect()
        }
    }

    fun normalizeIp(raw: String): String {
        var value = raw.trim().removePrefix("\"").removeSuffix("\"")
        if (value.startsWith('[') && value.endsWith(']')) {
            value = value.substring(1, value.length - 1)
        }
        if (value.isEmpty()) throw IllegalArgumentException("empty ip")
        addressFamily(value)
        return value
    }

    fun addressFamily(ip: String): String {
        if (ip.contains(':')) {
            // A literal-only character check prevents DNS lookup of arbitrary response text.
            if (ip.any { it !in "0123456789abcdefABCDEF:." }) {
                throw IllegalArgumentException("出口 IP 服务返回了无效地址")
            }
            val address = runCatching { InetAddress.getByName(ip) }.getOrNull()
            if (address is Inet6Address) return "IPv6"
        } else {
            val octets = ip.split('.')
            if (octets.size == 4 && octets.all { octet ->
                    octet.isNotEmpty() && octet.all { it in '0'..'9' } &&
                        (octet.length == 1 || !octet.startsWith('0')) &&
                        octet.toIntOrNull() in 0..255
                }
            ) {
                return "IPv4"
            }
        }
        throw IllegalArgumentException("出口 IP 服务返回了无效地址")
    }
}
