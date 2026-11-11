#!/usr/bin/env bash
#
# Builds the trimmed Xray core as XRay.xcframework for iOS and macOS.
#
# Output goes to darwin/vless_dart/Artifacts/, which is where Package.swift
# expects it. The path must stay inside the SwiftPM package: Flutter symlinks
# the package into example/ios/Flutter/ephemeral/Packages/, so a binaryTarget
# path that escapes the package root resolves against that location instead.
#
# Requires full Xcode (not just Command Line Tools) — `gomobile bind -target=ios`
# needs the iphoneos and iphonesimulator SDKs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/third_party/xray-mobile"
OUT="$ROOT/darwin/vless_dart/Artifacts"
IOS_VERSION="${IOS_VERSION:-15.0}"
# Must match Package.swift and the host app. Without it gomobile defaults to
# the host SDK, which stamps objects with a far newer minimum than we claim.
MACOS_VERSION="${MACOS_VERSION:-13.0}"

export PATH="/opt/homebrew/bin:$PATH"
export PATH="$PATH:$(go env GOPATH)/bin"

if ! go version | grep -q 'darwin/arm64'; then
  echo "error: need an arm64 Go toolchain; found: $(go version)" >&2
  echo "  a stale x86_64 Go at /usr/local/go will shadow Homebrew's if PATH order flips" >&2
  exit 1
fi

if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
  echo "error: Xcode must be selected, not Command Line Tools" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

# `gomobile version` reports "binary is out of date" even when bind works, so
# check for the binary rather than trusting its self-report.
command -v gomobile >/dev/null || { echo "error: gomobile not installed" >&2; exit 1; }

WORK="$MODULE/build"
rm -rf "$WORK/ios" "$WORK/mac"
mkdir -p "$WORK/ios" "$WORK/mac" "$OUT"
cd "$MODULE"

# gomobile emits one xcframework per target, and names the inner framework
# after the output file. SwiftPM's binaryTarget takes a single xcframework, and
# -create-xcframework rejects mismatched module names — so both builds must be
# named XRay and then merged.
echo "==> building iOS"
gomobile bind -a -ldflags="-s -w" -target=ios -iosversion="$IOS_VERSION" \
  -o "$WORK/ios/XRay.xcframework" .

echo "==> building macOS"
gomobile bind -a -ldflags="-s -w" -target=macos -macosversion="$MACOS_VERSION" \
  -o "$WORK/mac/XRay.xcframework" .

echo "==> merging slices"
rm -rf "$OUT/XRay.xcframework"
xcodebuild -create-xcframework \
  -framework "$WORK/ios/XRay.xcframework/ios-arm64/XRay.framework" \
  -framework "$WORK/ios/XRay.xcframework/ios-arm64_x86_64-simulator/XRay.framework" \
  -framework "$WORK/mac/XRay.xcframework/macos-arm64_x86_64/XRay.framework" \
  -output "$OUT/XRay.xcframework" >/dev/null

echo
echo "==> slices"
ls "$OUT/XRay.xcframework" | grep -v Info.plist | sed 's/^/   /'

echo
echo "==> sizes"
du -sh "$OUT/XRay.xcframework"
find "$OUT/XRay.xcframework/ios-arm64" -name XRay -type f -exec du -h {} \; | sed 's/^/   device slice: /'

echo
echo "==> checksum for a remote binaryTarget"
(cd "$OUT" && rm -f XRay.xcframework.zip \
  && zip -qry XRay.xcframework.zip XRay.xcframework \
  && shasum -a 256 XRay.xcframework.zip | awk '{print "   sha256: "$1}' \
  && rm -f XRay.xcframework.zip)
