package dev.viasix.app.session

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DnsRoutingSurfaceTest {
    @Test
    fun settingsIntentServiceAndTunExposeProxyByDefaultWithExplicitDirectFallback() {
        val commands =
            resolve(
                "src/main/java/dev/viasix/app/session/VpnSessionCommands.kt",
                "app/src/main/java/dev/viasix/app/session/VpnSessionCommands.kt",
            ).readText()
        val service =
            resolve(
                "src/main/java/dev/viasix/app/vpn/ViaSixVpnService.kt",
                "app/src/main/java/dev/viasix/app/vpn/ViaSixVpnService.kt",
            ).readText()
        val engine =
            resolve(
                "src/main/java/dev/viasix/app/tun/Tun2SocksEngine.kt",
                "app/src/main/java/dev/viasix/app/tun/Tun2SocksEngine.kt",
            ).readText()
        val settings =
            resolve(
                "src/main/java/dev/viasix/app/ui/screens/SettingsScreen.kt",
                "app/src/main/java/dev/viasix/app/ui/screens/SettingsScreen.kt",
            ).readText()

        assertTrue(commands.contains("EXTRA_DNS_ROUTING_MODE"))
        assertTrue(commands.contains("EXTRA_DNS_SERVER"))
        assertTrue(service.contains("builder.addDnsServer(dnsServer)"))
        assertTrue(service.contains("dnsAddress is Inet6Address"))
        assertTrue(service.contains("IPv6 VPN route is required but could not be applied"))
        assertTrue(service.contains("dnsRoutingMode = dnsRoutingMode"))
        assertTrue(engine.contains("DnsRoutingMode.PROXY"))
        assertTrue(engine.contains("DnsSettingsPolicy.shouldUseProtectedDirect"))
        assertTrue(engine.contains("ProtectedSocketConnector.connect"))
        assertTrue(engine.contains("targetHost = dnsUpstream"))
        assertTrue(engine.contains("ProxyDnsExchange.exchangeWithSocket"))
        assertTrue(engine.contains("forwardDnsProxy(clientIp"))
        assertTrue(settings.contains("DNS 路由"))
        assertTrue(settings.contains("DNS 服务器（数字 IP）"))
        assertTrue(settings.contains("DNS 可经代理或直连"))
    }

    private fun resolve(vararg paths: String): File =
        paths.map { File(it) }.firstOrNull { it.isFile }
            ?: error("file not found from cwd=${File(".").absolutePath}: ${paths.toList()}")
}
