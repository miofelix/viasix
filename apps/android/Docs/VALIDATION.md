# Android validation — 2026-10-16

## Build and device

- Device: OPPO PKX110, Android 16 / API 36, arm64-v8a, connected through ADB.
- App: `dev.viasix.app`, version 1.0.1 / versionCode 2, debug APK with the packaged arm64 mihomo and CFST executables.
- Build: JDK 17, SHA-256-pinned Gradle 8.13 wrapper. In-process Kotlin compilation avoids reuse of an incompatible host Kotlin daemon.
- Supplied profile: `app/src/main/resources/viasix-mihomo.yaml`, byte-identical to the supplied file; SHA-256 `0a3b268de3487e185090d8338c01b10d95607c7cd48f3cce94e4faa017e70a55`.
- Defaults apply on first launch and preference reset. Custom applied profiles and unapplied drafts remain independent.

## Automated checks

Latest JVM results: **415 tests passed** (`:core` 57, `:app` 358), no failures or skips. `lintDebug` passed with no errors; warnings only report newer dependency versions. Debug app and instrumentation APKs assembled successfully.

Latest device run: **16 tests passed** on the connected OPPO PKX110 / Android 16 arm64 device, with no failures or skips. The suite includes 10 VPN/mihomo behavior tests and 6 UI/persistence tests.

```sh
cd apps/android
./gradlew :core:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
# Complete VPN consent in the app before running device tests.
./gradlew :app:connectedDebugAndroidTest -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true
```

The instrumentation suite checks the APK-packaged arm64 mihomo and CFST components, real mihomo IPv4/IPv6 SOCKS TCP with 256 KiB binary transfers and half-close; UDP DNS payload replies; controller authentication and secret rotation; repeated connect/disconnect and cancellation during startup; restart during shutdown; system restoration, MTU and routing preferences; actual GLOBAL proxy selection and RULE rules after mode transitions; navigation and UI persistence; invalid YAML and numeric input handling.

App-UID sockets bypass its own VPN to prevent loops. These socket assertions prove the real mihomo proxy, while external-UID tests below cover the Android TUN path.

## Android TUN and CF data path

With a full-tunnel VPN in DIRECT mode, external ADB-shell UID traffic fetched `https://www.baidu.com` successfully (HTTP 200), both with an explicit destination IPv4 and with DNS resolution. The new UDP DNS → SOCKS TCP bridge was observed connecting to `1.1.1.1:53`; actual TCP traffic appeared in the core log. This establishes a working TUN/DNS/TCP forwarding path independently of CF ingress reachability.

The CF configuration was independently tested using temporary listeners and forced `MATCH,ViaSix Cloudflare Pages` routing. Both CF IPv4 ingress addresses (`104.21.63.166`, `172.67.147.243`) transferred real data to explicit IPv4 destinations:

| Target | Result |
| --- | --- |
| AWS `checkip.amazonaws.com`, `18.139.211.133:80` | HTTP 200, CF IPv4 exit returned |
| Google `ifconfig.me/ip`, `34.160.111.145:443` | HTTPS certificate verified, HTTP 200, CF IPv4 exit returned |
| Microsoft `connecttest.txt`, `2.16.55.202:80` | HTTP 200, `Microsoft Connect Test` |

Both real CF IPv6 ingress addresses were subsequently verified from the host as well. `2606:4700:3035::6815:3fa6` and `2606:4700:3034::ac43:93f3` each returned HTTP 200 for the explicit AWS IPv4 and Google IPv4 destinations. The default IPv6 ingress returned IPv4 exits `104.28.162.50` / `104.28.155.187`. Live socket inspection confirmed the exact IPv6 peers on port 443, with no IPv4 ingress fallback. The host used its existing `utun10` path, so this establishes functioning CF IPv6 ingress and IPv4 egress through that host network, rather than native BUCEA Wi-Fi IPv6 connectivity on the phone. No system route was changed.

The same APK-packaged Android core also fetched the AWS and Google IPv4 targets through the real CF service (HTTP 200; exits `104.28.163.87` and `104.28.162.115`) when an **ADB TCP relay** temporarily supplied the otherwise unavailable first hop. TLS verification, UUID, SNI, WebSocket Host/path and proxy routing stayed enabled. This isolates Android TLS/VLESS compatibility and CF forwarding; it does **not** establish BUCEA IPv6 connectivity. The relay, diagnostic process, port mappings and temporary device profile were removed afterwards. The bundled default profile remains IPv6.

The default `api.myip.la` endpoint, replacement IPv4 sources `v4.ident.me` / AWS, and replacement IPv6 source `v6.ident.me` returned valid responses through CF in separate host diagnostics. Ingress and egress address families are independent; the app now detects the actual exit without treating an IPv6 ingress as proof of an IPv6 exit.

The existing CF deployment cannot directly connect to some Cloudflare-hosted destination addresses through its Worker TCP socket. This was reproduced for the old IPv4 detector `api-ipv4.ip.sb`, `api4.ipify.org` and geo provider `ipwho.is` (destination TLS EOF). The Android detector now uses verified compatible sources, and optional failed geo enrichment cannot invalidate a valid exit IP. No CF deployment or server code was changed.

## BUCEA network result and remaining limit

The phone receives only an `fd00:1050:a:123::/64` private IPv6 prefix and link-local addresses on Wi-Fi. It has an IPv6 default route; gateway `fe80::4277:a9ff:fe6b:d001%wlan0` answered both probes (~16 ms). This confirms local IPv6 reachability, rather than public IPv6 access.

With ViaSix stopped/bypassed, IPv4 HTTPS to Baidu returned HTTP 200. IPv6 HTTPS attempts to Baidu, AliDNS, Tsinghua mirrors and the selected CF IPv6 all timed out before TCP connection. The CF IPv4 addresses and two alternate CF IPv4 edges also timed out from the phone. The available evidence does not establish a working BUCEA public IPv6 egress.

Therefore the complete **phone → public IPv6 → CF → Internet IPv4 → phone** path and successful public IPv6 CFST measurements remain unverified on this Wi-Fi. Re-run those checks on a network with reachable CF IPv6 ingress. No success is inferred from the local VPN running indicator. Cellular handover was not tested because the device reported no usable SIM.

Local detailed evidence is retained under `build/reports/device-validation/`; JVM, lint and connected-test HTML/XML reports are under the normal module build directories. These build artifacts are intentionally not committed.
