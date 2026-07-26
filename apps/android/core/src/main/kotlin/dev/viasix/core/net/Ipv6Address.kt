package dev.viasix.core.net

import java.net.Inet6Address
import java.net.InetAddress

object Ipv6Address {
    fun isValid(value: String?): Boolean {
        val raw = normalize(value) ?: return false
        // Hostnames never contain ':'; requiring one guarantees
        // InetAddress parses a literal and never resolves via DNS.
        if (!raw.contains(':')) return false
        return try {
            InetAddress.getByName(raw) is Inet6Address
        } catch (_: Exception) {
            false
        }
    }

    /** Strip optional brackets and whitespace; return null if empty. */
    fun normalize(value: String?): String? {
        var raw = value?.trim().orEmpty()
        if (raw.isEmpty()) return null
        if (raw.startsWith('[') && raw.endsWith(']') && raw.length > 2) {
            raw = raw.substring(1, raw.length - 1)
        }
        // Drop zone id if present (fe80::1%wlan0)
        val percent = raw.indexOf('%')
        if (percent >= 0) {
            raw = raw.substring(0, percent)
        }
        return raw.ifEmpty { null }
    }

    fun display(value: String?): String = normalize(value) ?: ""
}
