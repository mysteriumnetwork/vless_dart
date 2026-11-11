# vless_dart

VLESS client for Flutter on **iOS and macOS**, built on a trimmed
[Xray-core](https://github.com/XTLS/Xray-core) and NetworkExtension.

## What it supports

VLESS over **WebSocket + TLS** — the transport the Mysterium backend serves.
Anything else (REALITY, XHTTP, gRPC, mKCP, QUIC) raises
`UnsupportedVlessConfigException` rather than connecting over the wrong
transport. Unknown query parameters in a `vless://` URI are ignored.

## Usage

```dart
final vpn = VlessDart();

await vpn.initialize(
  providerBundleIdentifier: 'com.example.app.XrayTunnel',
  localizedDescription: 'Example VPN',
);

if (!await vpn.checkTunnelConfiguration()) {
  await vpn.setupTunnel();            // prompts for VPN permission once
}

await vpn.connect(vlessUri);          // the raw vless:// URI from the API

vpn.statusStream().listen((status) => print(status.name));
final stats = await vpn.tunnelStatistics();
await vpn.disconnect();
```

`connect` takes the **raw URI**; parsing happens in Dart so a malformed or
unsupported config fails before anything reaches the platform.

> Credentials rotate per connection. Always connect with the URI from the latest
> API response — never cache or replay one.

## How it works

```
app traffic
  → NEPacketTunnelFlow (utun)
  → hev tun2socks
  → authenticated loopback SOCKS5
  → Xray  ──VLESS/WS/TLS──▶  server
```

The plugin owns the control plane (`NETunnelProviderManager`); the **host app**
owns the data plane. Each platform needs its own packet tunnel extension target
whose principal class subclasses `VlessPacketTunnelProvider`:

```swift
import vless_tunnel_support

class PacketTunnelProvider: VlessPacketTunnelProvider {}
```

Add the package's **`vless-tunnel-support`** product to that extension target
(not to the app target — the app gets `vless-dart` through Flutter).

The loopback SOCKS inbound binds a free port and gets fresh credentials per
session, both minted inside the extension so they never cross a process
boundary.

IPv6 is captured by the tunnel and dropped at Xray, so clients fall back to
IPv4. Leaving it uncaptured would route IPv6 *around* the tunnel, leaking the
user's real address on any dual-stack network.

## Building the Xray core

```sh
make build-core      # gomobile bind for iOS + macOS, merged into one xcframework
```

Output lands in `darwin/vless_dart/Artifacts/`, where `Package.swift` expects
it. Requires full Xcode (not just Command Line Tools) and an **arm64** Go
toolchain.

The feature set is `third_party/xray-mobile/distro.go` — editing that file is
how a protocol or transport gets added, and it is deliberately a visible,
reviewable change.

## Development

```sh
make check           # format + analyze + Dart, Go and Swift suites
make run-macos       # build, sync to the registered bundle, launch
make run-macos-auto  # same, connects on launch
make tunnel-logs     # stream the extension's os_log
make exit-ip         # confirm traffic leaves through the tunnel
```

`run-macos` syncs the build over the bundle LaunchServices has registered.
Without that step macOS keeps loading a stale copy of the extension, which looks
exactly like your changes having no effect.

## Licensing

See [NOTICE](NOTICE) for the third-party components this package builds on and
their licence terms.
