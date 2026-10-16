package dev.viasix.app.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Test
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class ExitIPDetectorTest {
    @Test
    fun parsesPlainTextIp() {
        val info = ExitIPDetector.parsePrimary("1.2.3.4\n")
        assertEquals("1.2.3.4", info.ip)
        assertEquals("IPv4", info.family)
    }

    @Test
    fun parsesJsonMyIpLaStyle() {
        val body =
            """
            {"ip":"2001:db8::1","location":{"city":"Tokyo","country_name":"Japan"}}
            """.trimIndent()
        val info = ExitIPDetector.parsePrimary(body)
        assertEquals("2001:db8::1", info.ip)
        assertEquals("IPv6", info.family)
        assertTrue(info.location.contains("Tokyo"))
    }

    @Test
    fun endpointSelection() {
        assertEquals(
            ExitIPDetector.IPV4_ENDPOINT,
            ExitIPDetector.endpointFor(ExitIPDetectionMode.IPV4, "https://example"),
        )
        assertEquals(
            "https://custom",
            ExitIPDetector.endpointFor(ExitIPDetectionMode.AUTOMATIC, "https://custom"),
        )
        assertEquals(
            ExitIPDetector.IPV6_ENDPOINT,
            ExitIPDetector.endpointFor(ExitIPDetectionMode.IPV6, "https://example"),
        )
    }

    @Test
    fun automaticDetectionUsesConfiguredEndpointThenIpv4ThenIpv6() {
        assertEquals(
            listOf(
                ExitIPDetectionMode.AUTOMATIC,
                ExitIPDetectionMode.IPV4,
                ExitIPDetectionMode.IPV6,
            ),
            ExitIPDetector.detectionAttemptModes(ExitIPDetectionMode.AUTOMATIC),
        )
        assertEquals(
            listOf(ExitIPDetectionMode.IPV4),
            ExitIPDetector.detectionAttemptModes(ExitIPDetectionMode.IPV4),
        )
        assertEquals(
            listOf(ExitIPDetectionMode.IPV6),
            ExitIPDetector.detectionAttemptModes(ExitIPDetectionMode.IPV6),
        )
    }

    @Test
    fun runningRuntimeUsesLoopbackMixedHttpProxy() {
        val selected = ExitIPRoutePolicy.proxyForRuntime(running = true, mixedPort = 11451)
        val javaProxy = requireNotNull(selected).asJavaProxy()
        val address = javaProxy.address() as InetSocketAddress

        assertEquals(Proxy.Type.HTTP, javaProxy.type())
        assertEquals("127.0.0.1", address.hostString)
        assertEquals(11451, address.port)
        assertEquals(ExitIPRoute.MIXED_PROXY, ExitIPRoutePolicy.routeFor(selected))
        assertEquals(ExitIPRoute.MIXED_PROXY, ExitIPRoutePolicy.routeForRuntime(running = true))
        assertEquals(ExitIPRoute.DIRECT, ExitIPRoutePolicy.routeForRuntime(running = false))
        assertNull(ExitIPRoutePolicy.proxyForRuntime(running = false, mixedPort = 11451))
    }

    @Test
    fun explicitAddressFamilyRejectsMismatchedResponse() {
        val error =
            assertThrows(IllegalArgumentException::class.java) {
                ExitIPDetector.validateExpectedFamily(
                    mode = ExitIPDetectionMode.IPV6,
                    info = ExitIPInfo(ip = "203.0.113.1", family = "IPv4"),
                )
            }

        assertTrue(error.message.orEmpty().contains("IPv6"))
    }

    @Test
    fun automaticUsesCustomEndpointAndExistingLocationWithoutAnIpv6OrGeoDetour() {
        val proxy = ExitIPProxy("127.0.0.1", 11451)
        val requested = mutableListOf<String>()
        val result = ExitIPDetector.detect(
            automaticEndpoint = "https://custom.invalid/ip",
            proxy = proxy,
            request = ExitIPRequest { url, _, actualProxy ->
                assertSame(proxy, actualProxy)
                requested += url
                """{"ip":"203.0.113.10","location":{"country_name":"Germany"}}"""
            },
        ).getOrThrow()

        assertEquals(listOf("https://custom.invalid/ip"), requested)
        assertEquals("203.0.113.10", result.ip)
        assertEquals("IPv4", result.family)
        assertEquals("Germany", result.location)
        assertEquals(ExitIPRoute.MIXED_PROXY, result.route)
    }

    @Test
    fun automaticCanReportAnActualIpv6ExitFromTheConfiguredDualStackService() {
        val requested = mutableListOf<String>()
        val result = ExitIPDetector.detect(
            enrich = false,
            request = ExitIPRequest { url, _, _ ->
                requested += url
                "2001:db8::8"
            },
        ).getOrThrow()

        assertEquals(listOf(ExitIPDetector.DEFAULT_ENDPOINT), requested)
        assertEquals("IPv6", result.family)
    }

    @Test
    fun ipv4FallsBackToAnIndependentServiceWithoutChangingTheProxyRoute() {
        val proxy = ExitIPProxy("127.0.0.1", 11451)
        val requested = mutableListOf<String>()
        val result = ExitIPDetector.detect(
            mode = ExitIPDetectionMode.IPV4,
            enrich = false,
            proxy = proxy,
            request = ExitIPRequest { url, _, actualProxy ->
                requested += url
                assertSame(proxy, actualProxy)
                if (url == ExitIPDetector.IPV4_ENDPOINT) throw IOException("provider unavailable")
                "203.0.113.25\n"
            },
        ).getOrThrow()

        assertEquals(listOf(ExitIPDetector.IPV4_ENDPOINT, ExitIPDetector.IPV4_FALLBACK_ENDPOINT), requested)
        assertEquals("203.0.113.25", result.ip)
        assertEquals("IPv4", result.family)
        assertEquals(ExitIPRoute.MIXED_PROXY, result.route)
    }

    @Test
    fun explicitIpv4NeverAcceptsAnIpv6ResponseAsItsResult() {
        val requested = mutableListOf<String>()
        val result = ExitIPDetector.detect(
            mode = ExitIPDetectionMode.IPV4,
            enrich = false,
            request = ExitIPRequest { url, _, _ ->
                requested += url
                if (url == ExitIPDetector.IPV4_ENDPOINT) "2001:db8::1" else "203.0.113.8"
            },
        ).getOrThrow()

        assertEquals(2, requested.size)
        assertEquals("203.0.113.8", result.ip)
        assertEquals("IPv4", result.family)
    }

    @Test
    fun explicitIpv6FailsAccuratelyInsteadOfFallingBackToIpv4() {
        val requested = mutableListOf<String>()
        val result = ExitIPDetector.detect(
            mode = ExitIPDetectionMode.IPV6,
            enrich = false,
            request = ExitIPRequest { url, _, _ ->
                requested += url
                "203.0.113.8"
            },
        )

        assertTrue(result.isFailure)
        assertTrue(result.exceptionOrNull()?.message.orEmpty().contains("IPv6"))
        assertEquals(listOf(ExitIPDetector.IPV6_ENDPOINT), requested)
    }

    @Test
    fun exhaustedProvidersAreBoundedAndAutomaticTriesIpv6OnlyAfterIpv4() {
        val requested = mutableListOf<String>()
        val result = ExitIPDetector.detect(
            automaticEndpoint = "https://custom.invalid/ip",
            enrich = false,
            request = ExitIPRequest { url, _, _ ->
                requested += url
                throw IOException("network unavailable")
            },
        )

        assertTrue(result.isFailure)
        assertEquals(listOf(
            "https://custom.invalid/ip",
            ExitIPDetector.DEFAULT_ENDPOINT,
            ExitIPDetector.IPV4_ENDPOINT,
            ExitIPDetector.IPV4_FALLBACK_ENDPOINT,
            ExitIPDetector.IPV6_ENDPOINT,
        ), requested)
    }

    @Test
    fun geolocationUsesTheSameProxyWithAShortTimeoutAndCannotInvalidateAValidIp() {
        val proxy = ExitIPProxy("127.0.0.1", 11451)
        val requested = mutableListOf<String>()
        val result = ExitIPDetector.detect(
            mode = ExitIPDetectionMode.IPV4,
            timeoutMs = 8000,
            proxy = proxy,
            request = ExitIPRequest { url, timeout, actualProxy ->
                requested += url
                assertSame(proxy, actualProxy)
                if (url.startsWith(ExitIPDetector.GEO_ENDPOINT)) {
                    assertTrue("optional geo lookup must not delay the IP result for a full primary timeout", timeout <= 1500)
                    throw IOException("CF-hosted geo service is unavailable")
                }
                "203.0.113.30"
            },
        ).getOrThrow()

        assertEquals("203.0.113.30", result.ip)
        assertEquals("IPv4", result.family)
        assertEquals(ExitIPRoute.MIXED_PROXY, result.route)
        assertEquals(2, requested.size)
    }

    @Test
    fun successfulGeoEnrichmentPreservesTheOriginalIpAndRoute() {
        val proxy = ExitIPProxy("127.0.0.1", 11451)
        val result = ExitIPDetector.detect(
            mode = ExitIPDetectionMode.IPV4,
            proxy = proxy,
            request = ExitIPRequest { url, _, actualProxy ->
                assertSame(proxy, actualProxy)
                if (url.startsWith(ExitIPDetector.GEO_ENDPOINT)) {
                    """{"ip":"203.0.113.31","country":"Germany","city":"Frankfurt","connection":{"isp":"Example ISP"}}"""
                } else {
                    "203.0.113.31"
                }
            },
        ).getOrThrow()

        assertEquals("203.0.113.31", result.ip)
        assertEquals(ExitIPRoute.MIXED_PROXY, result.route)
        assertTrue(result.location.contains("Frankfurt"))
        assertTrue(result.details.contains("Example ISP"))
    }

    @Test
    fun errorPagesHostnamesAndMalformedLiteralsCannotBecomeFakeExitAddresses() {
        listOf(
            "Cloudflare error 1101", "<html>upstream unavailable</html>", "example.com",
            "1.2.3.999", "1.2.3", "01.2.3.4", "foo:bar", "::::", "2001:db8::1%wlan0",
            """{"ip":"upstream unavailable"}""",
        ).forEach { body ->
            assertThrows("must reject $body", IllegalArgumentException::class.java) {
                ExitIPDetector.parsePrimary(body)
            }
        }
    }

    @Test
    fun defaultTransportActuallyUsesTheSelectedHttpProxy() {
        val requestLine = AtomicReference<String>()
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { server ->
            server.soTimeout = 3000
            val worker = thread {
                server.accept().use { socket ->
                    socket.soTimeout = 3000
                    val reader = socket.getInputStream().bufferedReader()
                    requestLine.set(reader.readLine())
                    while (!reader.readLine().isNullOrEmpty()) { }
                    val body = "203.0.113.40\n"
                    val response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body"
                    socket.getOutputStream().write(response.toByteArray(Charsets.UTF_8))
                    socket.getOutputStream().flush()
                }
            }
            try {
                val result = ExitIPDetector.detect(
                    automaticEndpoint = "http://exit.invalid/test",
                    timeoutMs = 1000,
                    enrich = false,
                    proxy = ExitIPProxy("127.0.0.1", server.localPort),
                ).getOrThrow()

                assertEquals("203.0.113.40", result.ip)
                assertEquals(ExitIPRoute.MIXED_PROXY, result.route)
                worker.join(3000)
                assertFalse(worker.isAlive)
                assertEquals("GET http://exit.invalid/test HTTP/1.1", requestLine.get())
            } finally {
                server.close()
                worker.join(3000)
            }
        }
    }
}
