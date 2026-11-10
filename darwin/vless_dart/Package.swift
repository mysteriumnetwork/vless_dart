// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "vless_dart",
  platforms: [
    .iOS("15.0"),
    .macOS("12.0")
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
    .target(
      name: "vless_dart",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        "vless_tunnel_support"
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
    // Trimmed Xray core — VLESS over WebSocket + TLS only. Built by
    // scripts/build_xray_apple.sh; see docs/superpowers/specs §6 and §11.
    //
    // Local path while we iterate. Switch to the remote form once the artifact
    // is published to GitHub releases:
    //
    //   .binaryTarget(
    //     name: "XRay",
    //     url: "https://github.com/mysteriumnetwork/vless_dart/releases/download/xray-<ver>/XRay.xcframework.zip",
    //     checksum: "8c5f1b2f0d8b2437ccb4bea26cc418ae4b9fecfea1df6197ddca126c7f5e8965"
    //   )
    // Path MUST stay inside the package: Flutter symlinks the package into
    // example/ios/Flutter/ephemeral/Packages/, and a path escaping the package
    // root resolves against that location instead.
    .binaryTarget(
      name: "XRay",
      path: "Artifacts/XRay.xcframework"
    )
  ]
)
