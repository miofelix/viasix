package dev.viasix.app.session

import dev.viasix.core.profile.ProfileSummary
import dev.viasix.core.profile.ProfileSummaryParser

/**
 * Memoizing front for [ProfileSummaryParser]: UI state getters re-derive summaries on
 * every recomposition and status poll, so repeat parses of an unchanged YAML string
 * must be free (SnakeYAML on the main thread otherwise dominates editor typing latency).
 */
internal class MemoizedProfileSummaryParser(
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
    private val parse: (String) -> ProfileSummary = ProfileSummaryParser::parse,
) {
    private val lock = Any()
    private val cache =
        object : LinkedHashMap<String, ProfileSummary>(maxEntries, 0.75f, true) {
            override fun removeEldestEntry(
                eldest: MutableMap.MutableEntry<String, ProfileSummary>,
            ): Boolean = size > maxEntries
        }

    init {
        require(maxEntries > 0) { "maxEntries must be positive" }
    }

    fun summaryFor(yamlText: String): ProfileSummary {
        synchronized(lock) { cache[yamlText] }?.let { return it }
        // Parse outside the lock: a slow parse must not block cached reads on other
        // threads. A duplicate concurrent parse is acceptable; first write wins.
        val parsed = parse(yamlText)
        return synchronized(lock) { cache.putIfAbsent(yamlText, parsed) ?: parsed }
    }

    companion object {
        /** Applied profile + draft, plus headroom for transient edit states. */
        private const val DEFAULT_MAX_ENTRIES = 4

        val shared = MemoizedProfileSummaryParser()
    }
}
