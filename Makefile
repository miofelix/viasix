# ViaSix monorepo orchestrator.
# Platform-specific builds live under apps/*; this file only delegates.

MACOS_DIR := apps/macos
WINDOWS_DIR := apps/windows
ANDROID_DIR := apps/android
CONTRACTS_DIR := contracts

.PHONY: \
	help \
	macos-build \
	macos-test \
	macos-check \
	macos-app \
	macos-clean \
	windows-skeleton \
	windows-test \
	windows-build-docs \
	android-skeleton \
	android-test \
	android-assemble \
	android-assemble-release \
	projection-test \
	shared-test \
	contracts-check \
	check \
	check-all

help:
	@echo "ViaSix monorepo targets:"
	@echo "  make macos-check       - lint, build, test macOS app"
	@echo "  make macos-app         - package ad-hoc ViaSix.app"
	@echo "  make macos-build       - swift build (macOS)"
	@echo "  make macos-test        - swift test (macOS)"
	@echo "  make macos-clean       - clean macOS build artifacts"
	@echo "  make contracts-check   - verify contracts layout + case.json schema"
	@echo "  make windows-skeleton  - verify Windows app tree"
	@echo "  make windows-test      - Rust contract projection tests (Windows host crate)"
	@echo "  make windows-build-docs - verify Windows release docs exist"
	@echo "  make android-skeleton  - verify Android app tree"
	@echo "  make android-test      - Android JVM tests (:core + :app)"
	@echo "  make android-assemble  - assemble debug APK (requires Android SDK)"
	@echo "  make android-assemble-release - signed release APK (needs signing/)"
	@echo "  make projection-test   - all platforms contracts fixtures only"
	@echo "  make shared-test       - packages/viasix-mihomo-config tests"
	@echo "  make check             - contracts + macOS + windows-test + android-test"
	@echo "  make check-all         - check + platform skeletons"

macos-build:
	$(MAKE) -C $(MACOS_DIR) build

macos-test:
	$(MAKE) -C $(MACOS_DIR) test

macos-check:
	$(MAKE) -C $(MACOS_DIR) check

macos-app:
	$(MAKE) -C $(MACOS_DIR) app

macos-clean:
	$(MAKE) -C $(MACOS_DIR) clean

contracts-check:
	@test -f "$(CONTRACTS_DIR)/VERSION"
	@test -f "$(CONTRACTS_DIR)/schemas/local-proxy.schema.json"
	@test -f "$(CONTRACTS_DIR)/schemas/x-viasix.schema.json"
	@test -d "$(CONTRACTS_DIR)/fixtures/mihomo-config/cases"
	@cases=0; \
	for dir in "$(CONTRACTS_DIR)/fixtures/mihomo-config/cases"/*; do \
	  [ -d "$$dir" ] || continue; \
	  test -f "$$dir/case.json" || { echo "missing case.json in $$dir"; exit 1; }; \
	  test -f "$$dir/input.yaml" || { echo "missing input.yaml in $$dir"; exit 1; }; \
	  cases=$$((cases + 1)); \
	done; \
	test "$$cases" -ge 1 || { echo "no contract fixture cases found"; exit 1; }; \
	node packages/mihomo-config/scripts/validate-cases.mjs; \
	echo "contracts layout OK (version $$(cat "$(CONTRACTS_DIR)/VERSION"), $$cases cases)"

windows-skeleton:
	@test -f "$(WINDOWS_DIR)/README.md"
	@test -f "$(WINDOWS_DIR)/package.json"
	@test -f "$(WINDOWS_DIR)/src-tauri/Cargo.toml"
	@test -f "$(WINDOWS_DIR)/src-tauri/src/projection/mod.rs"
	@test -f "$(WINDOWS_DIR)/src-tauri/src/speed_test/mod.rs"
	@test -f "$(WINDOWS_DIR)/scripts/fetch-mihomo.mjs"
	@test -f "$(WINDOWS_DIR)/scripts/fetch-cfst.mjs"
	@test -f "$(WINDOWS_DIR)/scripts/fetch-wintun.mjs"
	@test -f "$(WINDOWS_DIR)/src/main.ts"
	@test -f "packages/viasix-mihomo-config/Cargo.toml"
	@echo "windows skeleton OK"

windows-test:
	cargo test --manifest-path "$(WINDOWS_DIR)/src-tauri/Cargo.toml"

windows-build-docs:
	@test -f "$(WINDOWS_DIR)/Docs/RELEASING.md"
	@test -f ".github/workflows/windows-build.yml"
	@node "$(WINDOWS_DIR)/scripts/check-version-align.mjs"
	@echo "windows build docs OK"

android-skeleton:
	@test -f "$(ANDROID_DIR)/README.md"
	@test -f "$(ANDROID_DIR)/settings.gradle.kts"
	@test -f "$(ANDROID_DIR)/app/src/main/AndroidManifest.xml"
	@test -f "$(ANDROID_DIR)/app/src/main/java/dev/viasix/app/MainActivity.kt"
	@test -f "$(ANDROID_DIR)/app/src/main/java/dev/viasix/app/vpn/ViaSixVpnService.kt"
	@test -f "$(ANDROID_DIR)/core/src/main/kotlin/dev/viasix/core/projection/MihomoProjection.kt"
	@test -f "$(ANDROID_DIR)/core/src/main/kotlin/dev/viasix/core/speedtest/SpeedTestResultParser.kt"
	@test -f "$(ANDROID_DIR)/app/src/main/java/dev/viasix/app/mihomo/MihomoInstaller.kt"
	@test -f "$(ANDROID_DIR)/app/src/main/java/dev/viasix/app/mihomo/MihomoProcess.kt"
	@test -f "$(ANDROID_DIR)/app/src/main/java/dev/viasix/app/cfst/CfstInstaller.kt"
	@test -f "$(ANDROID_DIR)/app/src/main/java/dev/viasix/app/cfst/CfstRunner.kt"
	@test -f "$(ANDROID_DIR)/scripts/fetch-mihomo.mjs"
	@test -f "$(ANDROID_DIR)/scripts/fetch-cfst.mjs"
	@test -f "$(ANDROID_DIR)/app/src/main/assets/cfst/ipv6.txt"
	@echo "android skeleton OK"

android-test:
	cd "$(ANDROID_DIR)" && ./gradlew :core:test :app:test --no-daemon

android-assemble:
	@test -s "$(ANDROID_DIR)/app/src/main/jniLibs/arm64-v8a/libmihomo.so" || \
		(echo "error: missing libmihomo.so — run: cd apps/android && node scripts/fetch-mihomo.mjs" >&2; exit 1)
	@test -s "$(ANDROID_DIR)/app/src/main/jniLibs/arm64-v8a/libcfst.so" || \
		(echo "error: missing libcfst.so — run: cd apps/android && node scripts/fetch-cfst.mjs" >&2; exit 1)
	cd "$(ANDROID_DIR)" && ./gradlew :app:assembleDebug --no-daemon

android-assemble-release:
	@test -s "$(ANDROID_DIR)/app/src/main/jniLibs/arm64-v8a/libmihomo.so" || \
		(echo "error: missing libmihomo.so — run: cd apps/android && node scripts/fetch-mihomo.mjs" >&2; exit 1)
	@test -s "$(ANDROID_DIR)/app/src/main/jniLibs/arm64-v8a/libcfst.so" || \
		(echo "error: missing libcfst.so — run: cd apps/android && node scripts/fetch-cfst.mjs" >&2; exit 1)
	@test -f signing/android/keystore.properties || \
		(echo "error: missing signing/android/keystore.properties — see signing/README.md" >&2; exit 1)
	cd "$(ANDROID_DIR)" && ./gradlew :app:assembleRelease --no-daemon

shared-test:
	cargo test --manifest-path packages/viasix-mihomo-config/Cargo.toml

projection-test: contracts-check shared-test
	@echo "==> macOS ContractFixtureTests"
	cd apps/macos && swift test --filter ContractFixtureTests
	@echo "==> Windows Rust contracts"
	$(MAKE) windows-test
	@echo "==> Android JVM contracts"
	$(MAKE) android-test
	@echo "projection-test OK (shared + macOS + Windows + Android)"

check: contracts-check shared-test macos-check windows-test android-test

check-all: check windows-skeleton android-skeleton
