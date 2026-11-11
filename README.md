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

## The Xray core

`Package.swift` links a published `XRay.xcframework` by default, so a clone
builds with no Go toolchain — SwiftPM downloads it and verifies its checksum.

To work on the core itself:

```sh
make build-core               # gomobile bind for iOS + macOS, merged + verified
make build-macos LOCAL_CORE=1 # link that local build instead of the release
make clean-core               # drop it and go back to the release
```

`LOCAL_CORE=1` sets `VLESS_LOCAL_CORE`, which `Package.swift` reads. It has to
be an environment variable rather than a check for the artifact on disk:
SwiftPM caches manifest evaluation, and only a change to the manifest's
contents or its environment re-triggers it, so a disk check would be served
stale. Building the core needs full Xcode (not just Command Line Tools) and an
**arm64** Go toolchain.

The feature set is `third_party/xray-mobile/distro.go` — editing that file is
how a protocol or transport gets added, and it is deliberately a visible,
reviewable change.

### Publishing a new core

The artifact is ~59 MB and is rebuilt on every Xray bump, so it is not
committed.

1. Commit the change to `third_party/xray-mobile` or to the build script.
2. Tag **that commit** `xray-v<version>` and push the tag. The *Release Xray
   core* workflow builds and publishes it.
3. Copy the `url` and `checksum` from the job summary into the `binaryTarget`
   in `darwin/vless_dart/Package.swift`, and commit that.

The workflow builds the tagged tree, not your working copy — tagging a commit
that predates the change republishes the old core, and the run still goes
green. `build_xray_apple.sh` guards the common case by checking each slice's
deployment target against `IOS_VERSION`/`MACOS_VERSION` and failing instead of
shipping a core that does not honour the floor `Package.swift` claims.

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

`test-swift` raises the macOS floor of the Flutter-generated plugin package
before running. Flutter pins that package to 10.15, below this one's floor;
Xcode's build action tolerates the mismatch but the test action refuses to link
against it.

## Licensing

See [NOTICE](NOTICE) for the third-party components this package builds on and
their licence terms.
