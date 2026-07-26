package dev.viasix.core.projection

import org.yaml.snakeyaml.DumperOptions
import org.yaml.snakeyaml.Yaml
import java.net.Inet6Address
import java.net.InetAddress

enum class RoutingMode(val wire: String) {
    RULE("rule"),
    GLOBAL("global"),
    DIRECT("direct");

    companion object {
        fun parse(raw: String): RoutingMode? =
            entries.firstOrNull { it.wire == raw || it.name.equals(raw, ignoreCase = true) }
    }
}

enum class ProjectionKind {
    USER,
    PRIVILEGED_TUN;

    companion object {
        fun parse(raw: String): ProjectionKind? =
            when (raw) {
                "user" -> USER
                "privilegedTun" -> PRIVILEGED_TUN
                else -> null
            }
    }
}

sealed class ProjectError(message: String) : Exception(message) {
    data object SelectedNodeMustBeIPv6 : ProjectError("selectedNodeMustBeIPv6")
    data object Ipv6ManagedProfileRequired : ProjectError("ipv6ManagedProfileRequired")
    data object MissingTunConfiguration : ProjectError("missingTunConfiguration")
    class InvalidYaml(detail: String) : ProjectError("invalidYAML: $detail")
    class UnsupportedProfileExtension(detail: String) :
        ProjectError("unsupportedProfileExtension: $detail")

    val contractCode: String
        get() =
            when (this) {
                SelectedNodeMustBeIPv6 -> "selectedNodeMustBeIPv6"
                Ipv6ManagedProfileRequired -> "ipv6ManagedProfileRequired"
                MissingTunConfiguration -> "missingTunConfiguration"
                is InvalidYaml -> "invalidYAML"
                is UnsupportedProfileExtension -> "unsupportedProfileExtension"
            }
}

data class ProjectOptions(
    val routingMode: RoutingMode = RoutingMode.RULE,
    val projection: ProjectionKind = ProjectionKind.USER,
    val selectedAddress: String? = null,
    val listenAddress: String = "127.0.0.1",
    val mixedPort: Int = 11451,
    val controllerPort: Int = 9090,
    val controllerSecret: String? = null,
    val logLevel: String = "info",
    val ipv6Enabled: Boolean = true,
    val udpEnabled: Boolean = true,
    val sniffingEnabled: Boolean = true,
)

object MihomoProjection {
    @Suppress("UNCHECKED_CAST")
    fun project(profileYaml: String?, options: ProjectOptions): Map<String, Any?> {
        if (options.projection == ProjectionKind.PRIVILEGED_TUN) {
            throw ProjectError.MissingTunConfiguration
        }

        val runtime = linkedMapOf<String, Any?>(
            "mixed-port" to options.mixedPort,
            "allow-lan" to false,
            "bind-address" to options.listenAddress,
            "mode" to options.routingMode.wire,
            "log-level" to options.logLevel,
            "ipv6" to options.ipv6Enabled,
            "unified-delay" to true,
            "tcp-concurrent" to true,
            "profile" to mapOf(
                "store-selected" to false,
                "store-fake-ip" to false,
            ),
        )
        val secret = options.controllerSecret?.trim().orEmpty()
        if (secret.isNotEmpty() && options.controllerPort in 1..65535 &&
            options.controllerPort != options.mixedPort
        ) {
            runtime["external-controller"] = "127.0.0.1:${options.controllerPort}"
            runtime["secret"] = secret
        }

        if (options.routingMode == RoutingMode.DIRECT) {
            runtime["rules"] = listOf("MATCH,DIRECT")
            runtime["tun"] = mapOf("enable" to false)
            return runtime
        }

        val yamlText = profileYaml?.trim().orEmpty()
        if (yamlText.isEmpty()) throw ProjectError.Ipv6ManagedProfileRequired

        val root = parseMapping(yamlText)
        validateViaSixExtension(root)
        val selected = resolveSelected(options.selectedAddress)
        val primary = extractPrimary(root, selected).toMutableMap()
        val allowsUdp = (primary["udp"] as? Boolean) ?: true
        primary["udp"] = options.udpEnabled && allowsUdp
        runtime["proxies"] = listOf(primary)

        if (options.sniffingEnabled) {
            runtime["sniffer"] = sniffer()
        }

        when (options.routingMode) {
            RoutingMode.GLOBAL -> runtime.remove("rules")
            RoutingMode.RULE -> {
                val name = primary["name"]?.toString()?.trim().orEmpty()
                if (name.isEmpty()) throw ProjectError.Ipv6ManagedProfileRequired
                runtime["rules"] = privateBypassRules() + "MATCH,$name"
            }
            RoutingMode.DIRECT -> Unit
        }

        runtime["tun"] = mapOf("enable" to false)
        for (key in listOf(
            "proxy-providers",
            "proxy-groups",
            "rule-providers",
            "sub-rules",
            "x-viasix",
        )) {
            runtime.remove(key)
        }
        return runtime
    }

    fun projectYaml(profileYaml: String?, options: ProjectOptions): String {
        val mapping = project(profileYaml, options)
        val optionsYaml = DumperOptions().apply {
            defaultFlowStyle = DumperOptions.FlowStyle.BLOCK
            isPrettyFlow = true
            indent = 2
        }
        val body = Yaml(optionsYaml).dump(mapping)
        return "# Generated by ViaSix for Mihomo\n$body"
    }

    @Suppress("UNCHECKED_CAST")
    private fun parseMapping(yaml: String): Map<String, Any?> {
        return try {
            when (val value = Yaml().load<Any?>(yaml)) {
                null -> emptyMap()
                is Map<*, *> -> value as Map<String, Any?>
                else -> throw ProjectError.InvalidYaml("top level must be mapping")
            }
        } catch (e: ProjectError) {
            throw e
        } catch (e: Exception) {
            throw ProjectError.InvalidYaml(e.message ?: "parse failed")
        }
    }

    private fun validateViaSixExtension(root: Map<String, Any?>) {
        val raw = root["x-viasix"] ?: return
        val mapping = raw as? Map<*, *>
            ?: throw ProjectError.UnsupportedProfileExtension("x-viasix must be a mapping")
        val supportedKeys = setOf("version", "primary-server")
        val unknown = mapping.keys.map { it.toString() }.sorted().firstOrNull { it !in supportedKeys }
        if (unknown != null) {
            throw ProjectError.UnsupportedProfileExtension("unknown key x-viasix.$unknown")
        }
        val version = mapping["version"]
        if (version !is Int || version != 1) {
            throw ProjectError.UnsupportedProfileExtension("x-viasix.version must be 1")
        }
        val primaryServer = mapping["primary-server"]
        if (primaryServer != null && primaryServer != "selected-ip") {
            throw ProjectError.UnsupportedProfileExtension(
                "x-viasix.primary-server only supports selected-ip",
            )
        }
    }

    private fun resolveSelected(selected: String?): String {
        val raw = selected?.trim().orEmpty()
        if (raw.isEmpty() || !isIpv6(raw)) throw ProjectError.SelectedNodeMustBeIPv6
        return raw
    }

    private fun isIpv6(value: String): Boolean {
        // Hostnames never contain ':'; requiring one guarantees
        // InetAddress parses a literal and never resolves via DNS.
        if (!value.contains(':')) return false
        return try {
            InetAddress.getByName(value) is Inet6Address
        } catch (_: Exception) {
            false
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun extractPrimary(root: Map<String, Any?>, selected: String): Map<String, Any?> {
        val proxies = root["proxies"] as? List<*>
            ?: throw ProjectError.Ipv6ManagedProfileRequired
        val maps = proxies.mapNotNull { it as? Map<*, *> }
        val index = primaryIndex(root, maps) ?: throw ProjectError.Ipv6ManagedProfileRequired
        val primary = maps[index].entries.associate { it.key.toString() to it.value }.toMutableMap()
        val name = primary["name"]?.toString()?.trim().orEmpty()
        val type = primary["type"]?.toString()?.trim().orEmpty()
        if (name.isEmpty() || type.isEmpty()) throw ProjectError.Ipv6ManagedProfileRequired
        primary["server"] = selected
        return primary
    }

    private fun primaryIndex(root: Map<String, Any?>, proxies: List<Map<*, *>>): Int? {
        proxies.forEachIndexed { index, proxy ->
            val server = proxy["server"]?.toString()?.trim().orEmpty()
            if (server.isNotEmpty()) return index
        }
        val selectedIp =
            (root["x-viasix"] as? Map<*, *>)?.get("primary-server")?.toString() == "selected-ip"
        if (!selectedIp) return null
        return proxies.indexOfFirst { proxy ->
            val type = proxy["type"]?.toString()?.lowercase().orEmpty()
            type !in setOf("direct", "reject", "dns")
        }.takeIf { it >= 0 }
    }

    private fun privateBypassRules(): List<String> =
        listOf(
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR6,::1/128,DIRECT,no-resolve",
            "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
            "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
        )

    private fun sniffer(): Map<String, Any?> =
        mapOf(
            "enable" to true,
            "force-dns-mapping" to true,
            "parse-pure-ip" to true,
            "override-destination" to true,
            "sniff" to mapOf(
                "HTTP" to mapOf(
                    "ports" to listOf("80", "8080-8880"),
                    "override-destination" to true,
                ),
                "TLS" to mapOf("ports" to listOf("443", "8443")),
                "QUIC" to mapOf("ports" to listOf("443", "8443")),
            ),
        )
}
