package dev.viasix.core.projection

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

class MihomoProjectionTest {
    private val inlineProfile =
        """
        proxies:
          - name: edge
            type: vless
            server: origin.example.com
            port: 443
            uuid: 11111111-1111-4111-8111-111111111111
        """.trimIndent()

    private fun options(selected: String = "2606:4700::8") =
        ProjectOptions(selectedAddress = selected)

    private fun profileWithExtension(extensionYaml: String): String =
        inlineProfile + "\n" + extensionYaml.trimIndent()

    @Test
    fun rejectsHostnameSelectedAddressWithoutDnsResolution() {
        // A hostname with an AAAA record must never pass as an IPv6 literal.
        assertThrows<ProjectError.SelectedNodeMustBeIPv6> {
            MihomoProjection.project(inlineProfile, options(selected = "v6only.example.com"))
        }
    }

    @Test
    fun rejectsIpv4MappedSelectedAddress() {
        // ::ffff:a.b.c.d embeds an IPv4 endpoint, not a real IPv6 exit. The
        // contract rejects it uniformly across platforms.
        assertThrows<ProjectError.SelectedNodeMustBeIPv6> {
            MihomoProjection.project(inlineProfile, options(selected = "::ffff:203.0.113.8"))
        }
    }

    @Test
    fun rejectsUnsupportedXViasixVersion() {
        val profile =
            profileWithExtension(
                """
                x-viasix:
                  version: 2
                  primary-server: selected-ip
                """,
            )
        val error =
            assertThrows<ProjectError.UnsupportedProfileExtension> {
                MihomoProjection.project(profile, options())
            }
        assertEquals("unsupportedProfileExtension", error.contractCode)
    }

    @Test
    fun rejectsUnknownXViasixKey() {
        val profile =
            profileWithExtension(
                """
                x-viasix:
                  version: 1
                  listen-port: 1080
                """,
            )
        assertThrows<ProjectError.UnsupportedProfileExtension> {
            MihomoProjection.project(profile, options())
        }
    }

    @Test
    fun rejectsUnsupportedPrimaryServerValue() {
        val profile =
            profileWithExtension(
                """
                x-viasix:
                  version: 1
                  primary-server: first-proxy
                """,
            )
        assertThrows<ProjectError.UnsupportedProfileExtension> {
            MihomoProjection.project(profile, options())
        }
    }

    @Test
    fun acceptsSupportedXViasixExtension() {
        val profile =
            profileWithExtension(
                """
                x-viasix:
                  version: 1
                  primary-server: selected-ip
                """,
            )
        val root = MihomoProjection.project(profile, options())
        assertTrue((root["proxies"] as List<*>).isNotEmpty())
    }
}
