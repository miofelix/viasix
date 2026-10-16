package dev.viasix.app.prefs

/** The supplied connection profile, packaged with the app for offline first launch and reset. */
object DefaultProfile {
    val yaml: String by lazy {
        requireNotNull(DefaultProfile::class.java.getResourceAsStream("/viasix-mihomo.yaml")) {
            "Bundled ViaSix connection profile is missing"
        }.bufferedReader(Charsets.UTF_8).use { it.readText() }
    }

    // Cloudflare edge for the supplied Pages endpoint; users can replace it through IPv6 testing.
    const val selectedAddress = "2606:4700:3035::6815:3fa6"
}
