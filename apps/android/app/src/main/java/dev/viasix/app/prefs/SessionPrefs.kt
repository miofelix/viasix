package dev.viasix.app.prefs

import android.content.Context
import dev.viasix.core.speedtest.IPSourceMode
import dev.viasix.core.speedtest.SpeedTestParameters
import org.json.JSONArray
import org.json.JSONObject

/**
 * SharedPreferences-backed session state for the Android shell.
 * Speed-test fields align with macOS [UserPreferences] parameters + ipSourceMode.
 */
data class SessionPrefs(
    val profileYaml: String = DefaultProfile.yaml,
    /** Nullable for migration: absent means the draft should start from [profileYaml]. */
    val profileDraft: String? = null,
    /** Last primary destination, restored after rotation and process recreation. */
    val selectedSection: String = "overview",
    /** Avoid automatically prompting for notifications on every connection after denial. */
    val notificationPermissionRequested: Boolean = false,
    val selectedAddress: String = DefaultProfile.selectedAddress,
    val routingMode: String = "rule",
    val fullTunnel: Boolean = true,
    val vpnMtu: String = "1500",
    val vpnMetered: Boolean = true,
    val bypassLocalNetwork: Boolean = false,
    val ipv6RoutingMode: String = "tunnel",
    val dnsRoutingMode: String = "proxy",
    val dnsServer: String = "1.1.1.1",
    val appRoutingMode: String = "all",
    val selectedAppPackages: List<String> = emptyList(),
    val candidateAddresses: List<String> = emptyList(),
    val exitIPEndpoint: String = "https://api.myip.la/cn?json",
    val exitIPDetectionMode: String = "automatic",
    val ipSourceMode: String = IPSourceMode.IPV6.wire,
    val speedParameters: SpeedTestParameters = SpeedTestParameters.defaultsForRange(),
    val customIpFilePath: String = "",
) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("profileYaml", profileYaml)
            .put("profileDraft", profileDraft)
            .put("selectedSection", selectedSection)
            .put("notificationPermissionRequested", notificationPermissionRequested)
            .put("selectedAddress", selectedAddress)
            .put("routingMode", routingMode)
            .put("fullTunnel", fullTunnel)
            .put("vpnMtu", vpnMtu)
            .put("vpnMetered", vpnMetered)
            .put("bypassLocalNetwork", bypassLocalNetwork)
            .put("ipv6RoutingMode", ipv6RoutingMode)
            .put("dnsRoutingMode", dnsRoutingMode)
            .put("dnsServer", dnsServer)
            .put("appRoutingMode", appRoutingMode)
            .put(
                "selectedAppPackages",
                JSONArray().also { arr ->
                    selectedAppPackages.forEach { arr.put(it) }
                },
            )
            .put(
                "candidateAddresses",
                JSONArray().also { arr ->
                    candidateAddresses.forEach { arr.put(it) }
                },
            )
            .put("exitIPEndpoint", exitIPEndpoint)
            .put("exitIPDetectionMode", exitIPDetectionMode)
            .put("ipSourceMode", ipSourceMode)
            .put("customIpFilePath", customIpFilePath)
            .put("speedParameters", speedParameters.toJson())
            // Legacy keys kept for one-way migration readers (ignored on write path above).
            .put("lastSpeedIpRange", speedParameters.ipRange)
            .put(
                "speedUseBundledList",
                IPSourceMode.parse(ipSourceMode) == IPSourceMode.IPV6,
            )
            .put("speedDisableDownload", speedParameters.disableDownload)

    companion object {
        fun fromJson(raw: String?): SessionPrefs {
            if (raw.isNullOrBlank()) return SessionPrefs()
            return try {
                val o = JSONObject(raw)
                val candidates = mutableListOf<String>()
                val arr = o.optJSONArray("candidateAddresses")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val value = arr.optString(i).trim()
                        if (value.isNotEmpty()) candidates += value
                    }
                }
                val selectedAppPackages = mutableListOf<String>()
                val selectedApps = o.optJSONArray("selectedAppPackages")
                if (selectedApps != null) {
                    for (i in 0 until selectedApps.length()) {
                        val packageName = selectedApps.optString(i).trim()
                        if (packageName.isNotEmpty()) selectedAppPackages += packageName
                    }
                }
                val legacyMode =
                    when {
                        o.has("ipSourceMode") -> o.optString("ipSourceMode", IPSourceMode.IPV6.wire)
                        o.optBoolean("speedUseBundledList", false) -> IPSourceMode.IPV6.wire
                        else -> IPSourceMode.RANGE.wire
                    }
                val paramsObj = o.optJSONObject("speedParameters")
                val params =
                    if (paramsObj != null) {
                        speedTestParametersFromJson(paramsObj)
                    } else {
                        SpeedTestParameters(
                            ipRange =
                                o.optString("lastSpeedIpRange", SpeedTestParameters.DEFAULT_IPV6_RANGE)
                                    .ifBlank { SpeedTestParameters.DEFAULT_IPV6_RANGE },
                            disableDownload = o.optBoolean("speedDisableDownload", false),
                        )
                    }
                SessionPrefs(
                    profileYaml = o.optString("profileYaml", DefaultProfile.yaml),
                    profileDraft =
                        if (o.has("profileDraft") && !o.isNull("profileDraft")) {
                            o.optString("profileDraft", "")
                        } else {
                            null
                        },
                    selectedSection = o.optString("selectedSection", "overview"),
                    notificationPermissionRequested =
                        o.optBoolean("notificationPermissionRequested", false),
                    selectedAddress = o.optString("selectedAddress", DefaultProfile.selectedAddress),
                    routingMode = o.optString("routingMode", "rule"),
                    fullTunnel = o.optBoolean("fullTunnel", true),
                    vpnMtu = o.optString("vpnMtu", "1500"),
                    vpnMetered = o.optBoolean("vpnMetered", true),
                    bypassLocalNetwork = o.optBoolean("bypassLocalNetwork", false),
                    ipv6RoutingMode = o.optString("ipv6RoutingMode", "tunnel"),
                    dnsRoutingMode = o.optString("dnsRoutingMode", "proxy"),
                    dnsServer = o.optString("dnsServer", "1.1.1.1"),
                    appRoutingMode = o.optString("appRoutingMode", "all"),
                    selectedAppPackages = selectedAppPackages.distinct().take(200),
                    candidateAddresses = candidates,
                    exitIPEndpoint =
                        o.optString("exitIPEndpoint", "https://api.myip.la/cn?json")
                            .ifBlank { "https://api.myip.la/cn?json" },
                    exitIPDetectionMode = o.optString("exitIPDetectionMode", "automatic"),
                    ipSourceMode = legacyMode,
                    speedParameters = params,
                    customIpFilePath = o.optString("customIpFilePath", ""),
                )
            } catch (_: Exception) {
                SessionPrefs()
            }
        }
    }
}

fun SpeedTestParameters.toJson(): JSONObject =
    JSONObject()
        .put("ipFile", ipFile)
        .put("ipRange", ipRange)
        .put("threads", threads)
        .put("pingCount", pingCount)
        .put("downloadCount", downloadCount)
        .put("downloadTime", downloadTime)
        .put("latencyUpperBound", latencyUpperBound)
        .put("latencyLowerBound", latencyLowerBound)
        .put("lossRateUpperBound", lossRateUpperBound)
        .put("speedLowerBound", speedLowerBound)
        .put("colo", colo)
        .put("port", port)
        .put("url", url)
        .put("httping", httping)
        .put("httpingCode", httpingCode)
        .put("disableDownload", disableDownload)
        .put("allIP", allIP)
        .put("debug", debug)

fun speedTestParametersFromJson(o: JSONObject): SpeedTestParameters =
    SpeedTestParameters(
        ipFile = o.optString("ipFile", ""),
        ipRange =
            o.optString("ipRange", SpeedTestParameters.DEFAULT_IPV6_RANGE)
                .ifBlank { SpeedTestParameters.DEFAULT_IPV6_RANGE },
        threads = o.optInt("threads", SpeedTestParameters.DEFAULT_THREADS),
        pingCount = o.optInt("pingCount", SpeedTestParameters.DEFAULT_PING_COUNT),
        downloadCount = o.optInt("downloadCount", SpeedTestParameters.DEFAULT_DOWNLOAD_COUNT),
        downloadTime = o.optInt("downloadTime", SpeedTestParameters.DEFAULT_DOWNLOAD_TIME),
        latencyUpperBound = o.optInt("latencyUpperBound", SpeedTestParameters.DEFAULT_LATENCY_UPPER),
        latencyLowerBound = o.optInt("latencyLowerBound", SpeedTestParameters.DEFAULT_LATENCY_LOWER),
        lossRateUpperBound =
            o.optDouble("lossRateUpperBound", SpeedTestParameters.DEFAULT_LOSS_RATE_UPPER),
        speedLowerBound = o.optDouble("speedLowerBound", SpeedTestParameters.DEFAULT_SPEED_LOWER),
        colo = o.optString("colo", ""),
        port = o.optInt("port", SpeedTestParameters.DEFAULT_PORT),
        url = o.optString("url", ""),
        httping = o.optBoolean("httping", true),
        httpingCode = o.optInt("httpingCode", 0),
        disableDownload = o.optBoolean("disableDownload", false),
        allIP = o.optBoolean("allIP", false),
        debug = o.optBoolean("debug", false),
    )

class SessionPrefsStore(context: Context) {
    private val prefs =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun load(): SessionPrefs = SessionPrefs.fromJson(prefs.getString(KEY, null))

    fun save(value: SessionPrefs) {
        prefs.edit().putString(KEY, value.toJson().toString()).apply()
    }

    fun clear() {
        prefs.edit().remove(KEY).apply()
    }

    companion object {
        private const val PREFS_NAME = "viasix_session"
        private const val KEY = "session"
    }
}
