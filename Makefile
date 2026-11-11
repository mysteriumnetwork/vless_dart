.DEFAULT_GOAL := test

# ─── Setup ───────────────────────────────────────────────────────────────────
init:
	fvm flutter pub get

init-example:
	cd example && fvm flutter pub get

clean:
	fvm flutter clean
	cd example && fvm flutter clean

# ─── Quality ───────────────────────────────────────────────────────────────────
format:
	fvm dart format --line-length 100 .

analyze:
	fvm flutter analyze

test: init
	fvm flutter test

# Swift unit tests for the tunnel-support module, via the macOS example.
# `swift test` cannot resolve the package standalone: FlutterFramework is a path
# dependency that only exists inside a Flutter build.
test-swift:
	cd example/macos && xcodebuild test -workspace Runner.xcworkspace -scheme Runner \
	  -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates -quiet

test-go:
	cd third_party/xray-mobile && go test ./...

# format check + analyze + every suite, as CI would run it
check: format analyze test test-go test-swift

# ─── Example app ─────────────────────────────────────────────────────────────────
run-example: init-example
	cd example && fvm flutter run

build-example-apk: init-example
	cd example && fvm flutter build apk --debug

# ─── Xray core ───────────────────────────────────────────────────────────────────
# Builds iOS + macOS and merges them into one XCFramework under
# darwin/vless_dart/Artifacts/, where Package.swift expects it.
build-core:
	./scripts/build_xray_apple.sh

# ─── macOS run ───────────────────────────────────────────────────────────────────
# `flutter build macos` writes to example/build/macos, but LaunchServices
# resolves the packet tunnel extension to whichever .appex path it registered
# first — usually a stale copy under DerivedData. Running the fresh app then
# silently loads the OLD extension, which costs hours to spot. So: build, sync
# the bundle over the registered path, and launch from there.
MACOS_APP      := example/build/macos/Build/Products/Debug/vless_dart_example.app
MACOS_REGISTERED := $(shell ls -d ~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Debug/vless_dart_example.app 2>/dev/null | head -1)

build-macos: init-example
	cd example && fvm flutter build macos --debug $(flags)

# Builds, syncs to the registered bundle, and launches it.
run-macos: build-macos
	@test -n "$(MACOS_REGISTERED)" || { \
	  echo "No registered bundle found under DerivedData."; \
	  echo "Open example/macos/Runner.xcworkspace and build once, then retry."; \
	  exit 1; }
	@echo "==> syncing to $(MACOS_REGISTERED)"
	@rm -rf "$(MACOS_REGISTERED)"
	@rsync -a "$(MACOS_APP)/" "$(MACOS_REGISTERED)/"
	@echo "==> launching"
	@"$(MACOS_REGISTERED)/Contents/MacOS/vless_dart_example"

# Same, but connects on launch — for a hands-free check.
run-macos-auto: flags=--dart-define=VLESS_AUTOCONNECT=true
run-macos-auto: run-macos

# Streams the tunnel extension's os_log. Run in a second terminal.
tunnel-logs:
	log stream --style compact --info --debug \
	  --predicate 'process == "XrayTunnelMac" OR process == "XrayTunnel" OR process == "nesessionmanager"'

# Confirms traffic actually leaves through the tunnel.
exit-ip:
	@curl -s --max-time 10 https://api.ipify.org; echo
