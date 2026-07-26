package dev.viasix.core.net

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class Ipv6AddressTest {
    @Test
    fun acceptsCanonicalIpv6() {
        assertTrue(Ipv6Address.isValid("2001:db8::1"))
        assertTrue(Ipv6Address.isValid("[2001:db8::1]"))
        assertTrue(Ipv6Address.isValid("  fe80::1  "))
    }

    @Test
    fun rejectsIpv4AndGarbage() {
        assertFalse(Ipv6Address.isValid("1.2.3.4"))
        assertFalse(Ipv6Address.isValid(""))
        assertFalse(Ipv6Address.isValid("not-an-ip"))
        assertFalse(Ipv6Address.isValid(null))
    }

    @Test
    fun rejectsHostnamesWithoutDnsResolution() {
        // Hostnames must never be accepted, even when they resolve to AAAA
        // records: validation has to stay literal-only and network-free.
        assertFalse(Ipv6Address.isValid("v6only.example.com"))
        assertFalse(Ipv6Address.isValid("cafe.babe"))
        assertFalse(Ipv6Address.isValid("[v6only.example.com]"))
        assertFalse(Ipv6Address.isValid("localhost"))
    }

    @Test
    fun normalizesBracketsAndZone() {
        assertEquals("2001:db8::1", Ipv6Address.normalize("[2001:db8::1]"))
        assertEquals("fe80::1", Ipv6Address.normalize("fe80::1%wlan0"))
    }
}
