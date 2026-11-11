// swift-tools-version: 5.9

import PackageDescription

// Control plane only. The data plane lives in github.com/mysteriumnetwork/vless-apple
// and is linked by the packet tunnel extension: declaring it here too collides in the
// package graph, since Flutter pulls this plugin into the app automatically.
let package = Package(
  name: "vless_dart",
  platforms: [
    .iOS("15.0"),
    .macOS("13.0")
  ],
  products: [
    .library(name: "vless-dart", targets: ["vless_dart"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "vless_dart",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ]
    )
  ]
)
