// swift-tools-version: 5.9

import Foundation
import PackageDescription

// Trimmed Xray core — VLESS over WebSocket + TLS only, built by
// scripts/build_xray_apple.sh. See docs/superpowers/specs §6 and §11.
//
// Shipped as a -library xcframework, not a -framework one. Xcode embeds a
// binary target delivered as a .framework into the app bundle even when it
// wraps a static archive, then fails to codesign it and the iOS install dies
// with 0xe8008014. A library is linked and never embedded.
//
// The published release is the default, so a clone needs no Go toolchain. Set
// VLESS_LOCAL_CORE=1 (or `make <target> LOCAL_CORE=1`) to link a local build
// instead — required when changing third_party/xray-mobile. SwiftPM keys its
// manifest cache on the environment, so toggling it does re-evaluate; checking
// for the artifact on disk instead would be served stale from that cache.
//
// The local path MUST stay inside the package: Flutter symlinks the package
// into example/ios/Flutter/ephemeral/Packages/, so a path escaping the package
// root resolves against that location instead.
let xrayCore: Target
if ProcessInfo.processInfo.environment["VLESS_LOCAL_CORE"] == "1" {
  xrayCore = .binaryTarget(name: "XRay", path: "Artifacts/XRay.xcframework")
} else {
  xrayCore = .binaryTarget(
    name: "XRay",
    url: "https://github.com/mysteriumnetwork/vless_dart/releases/download/xray-v26.3.27-3/XRay.xcframework.zip",
    checksum: "9c647f8f4aeadcc32f008a55a8fe4b7ac48e8265718c5849151aff727e9c17ac"
  )
}

let package = Package(
  name: "vless_dart",
  platforms: [
    .iOS("15.0"),
    .macOS("13.0")
  ],
  products: [
    // For the app target: the Flutter plugin (control plane).
    .library(name: "vless-dart", targets: ["vless_dart"]),
    // For the packet tunnel extension target: everything the data plane needs.
    // The extension must NOT link Flutter, so this product is Flutter-free.
    .library(name: "vless-tunnel-support", targets: ["vless_tunnel_support"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
    .package(url: "https://github.com/EbrahimTahernejad/Tun2SocksKit", exact: "5.15.0")
  ],
  targets: [
    // Control plane only. It must NOT depend on vless_tunnel_support: that
    // would link the Xray core into the app process, and its Go runtime
    // collides with WireGuard's (duplicate _crosscall2 et al).
    .target(
      name: "vless_dart",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ]
    ),
    .target(
      name: "vless_tunnel_support",
      dependencies: [
        "XRay",
        .product(name: "Tun2SocksKit", package: "Tun2SocksKit"),
        .product(name: "Tun2SocksKitC", package: "Tun2SocksKit")
      ],
      // Go's net package resolves via libresolv (_res_9_ninit et al).
      linkerSettings: [.linkedLibrary("resolv")]
    ),
    xrayCore
  ]
)
