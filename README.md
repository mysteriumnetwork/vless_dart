# vless_dart

VLESS client for Flutter on **iOS and macOS**. The control plane; the tunnel
engine lives in
[vless-apple](https://github.com/mysteriumnetwork/vless-apple).

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

Add the **`vless-tunnel-support`** product from
[vless-apple](https://github.com/mysteriumnetwork/vless-apple) to that extension
target (not to the app target — the app gets `vless-dart` through Flutter).

The loopback SOCKS inbound binds a free port and gets fresh credentials per
session, both minted inside the extension so they never cross a process
boundary.

IPv6 is captured by the tunnel — leaving it uncaptured would route IPv6
*around* the tunnel, leaking the user's real address on any dual-stack network
— and then proxied rather than dropped. Dropping it reaches the client as
"connected, then closed", which Chrome never retries over IPv4. Names resolve
v4-only through the config's `queryStrategy` instead.

## The tunnel engine

The Xray core, the tun2socks bridge and `VlessPacketTunnelProvider` live in
[vless-apple](https://github.com/mysteriumnetwork/vless-apple), along with the
Swift suite and the instructions for building and publishing a core.

This package is deliberately free of them. It is pulled into the app process by
Flutter, and linking the core there would put a second Go runtime alongside
WireGuard's — which fails to link — besides colliding with vless-apple's targets
in the same package graph.

## Development

```sh
make check           # format + analyze + the Dart and Swift suites
make run-macos       # build, sync to the registered bundle, launch
make run-macos-auto  # same, connects on launch
make tunnel-logs     # stream the extension's os_log
make exit-ip         # confirm traffic leaves through the tunnel
```

`run-macos` syncs the build over the bundle LaunchServices has registered.
Without that step macOS keeps loading a stale copy of the extension, which looks
exactly like your changes having no effect.

`test-swift` covers the plugin's control plane, hosted by the macOS example
because the package depends on FlutterFramework and cannot run under
`swift test`. It raises the macOS floor of the Flutter-generated plugin package
first: Flutter hardcodes 10.15 there, below this package's floor, and Xcode's
test action refuses to link against the mismatch even though building tolerates
it.

## Licensing

MIT; see [LICENSE](LICENSE). The third-party components the tunnel engine
builds on are attributed in
[vless-apple](https://github.com/mysteriumnetwork/vless-apple)'s NOTICE.
