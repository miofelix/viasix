package dev.viasix.app.session

import dev.viasix.core.profile.ProfileSummary
import dev.viasix.core.profile.ProfileSummaryParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class MemoizedProfileSummaryParserTest {
    private val yamlA =
        """
        proxies:
          - name: A
            type: vless
            server: a.example.com
            port: 443
        x-viasix:
          version: 1
          primary-server: selected-ip
        """.trimIndent()

    private val yamlB = yamlA.replace("name: A", "name: B")

    @Test
    fun repeatedReadsOfIdenticalYamlParseOnlyOnce() {
        val parseCount = AtomicInteger(0)
        val parser =
            MemoizedProfileSummaryParser(
                parse = { text ->
                    parseCount.incrementAndGet()
                    ProfileSummaryParser.parse(text)
                },
            )

        val first = parser.summaryFor(yamlA)
        val second = parser.summaryFor(yamlA)
        val third = parser.summaryFor(String(yamlA.toCharArray()))

        assertEquals(1, parseCount.get())
        assertSame(first, second)
        // Equal-but-distinct string instances (editor round-trips) must also hit cache.
        assertSame(first, third)
    }

    @Test
    fun distinctYamlStringsParseIndependently() {
        val parseCount = AtomicInteger(0)
        val parser =
            MemoizedProfileSummaryParser(
                parse = { text ->
                    parseCount.incrementAndGet()
                    ProfileSummaryParser.parse(text)
                },
            )

        assertEquals("A", parser.summaryFor(yamlA).primary?.name)
        assertEquals("B", parser.summaryFor(yamlB).primary?.name)
        assertEquals(2, parseCount.get())
    }

    @Test
    fun matchesUnmemoizedParserOutput() {
        val parser = MemoizedProfileSummaryParser()
        assertEquals(ProfileSummaryParser.parse(yamlA), parser.summaryFor(yamlA))
        assertEquals(ProfileSummaryParser.parse(""), parser.summaryFor(""))
        assertEquals(
            ProfileSummaryParser.parse("proxies: ["),
            parser.summaryFor("proxies: ["),
        )
    }

    @Test
    fun evictsLeastRecentlyUsedEntryBeyondCapacity() {
        val parseCount = AtomicInteger(0)
        val parser =
            MemoizedProfileSummaryParser(
                maxEntries = 1,
                parse = { text ->
                    parseCount.incrementAndGet()
                    ProfileSummaryParser.parse(text)
                },
            )

        parser.summaryFor(yamlA)
        parser.summaryFor(yamlB)
        parser.summaryFor(yamlA)
        assertEquals(3, parseCount.get())
    }

    @Test
    fun sharedInstanceReturnsStableSummaryForSameString() {
        val summary = MemoizedProfileSummaryParser.shared.summaryFor(yamlA)
        assertSame(summary, MemoizedProfileSummaryParser.shared.summaryFor(yamlA))
    }
}
