## 0.4.2

* The Xray access log is off. With a log section present and no `access` in
  it, Xray wrote a line per connection to stdout, naming its destination:
  into logcat on Android and into the debug output on Windows.
* Windows: a DNS policy rule left by a core that was killed is cleared when
  the app starts, when the core dies under a tunnel, and when the plugin shuts
  down. The rule points every lookup on the machine at a resolver inside the
  tunnel, and until now only the next connect removed a leftover -- which an
  app that must reach its API by name could never get to.
* Windows: a core that exits on its own is reported on the status stream with
  its exit code, instead of as a bare `disconnected`, or as nothing at all
  when it died before answering a start.
* Windows: the core is launched by full path or not at all, inherits only its
  two pipes rather than every inheritable handle in the app, and is stopped
  together with anything it started. Its raw output, which includes each
  connection the bridge carries, reaches the debug output in debug builds
  only.
* Android: the core download is checked against a pinned SHA-256, as the
  Windows and Apple ones already were.
* CI builds the Android, iOS and macOS sides and runs the Kotlin and Swift
  tests, which ran nowhere before. The Windows job also tests the process
  handling around the core.

## 0.4.1

* Android runs the Xray core in its own process, `:vless`. The core and
  wireguard-go each carry a Go runtime, and two in one process is unsupported
  upstream (golang/go#65050): in a host that ships both, connecting WireGuard
  after VLESS had run killed the app with a SIGSEGV that left no tombstone,
  because Go replaces Android's crash handler. Apple was never affected, as
  each tunnel already has its own extension process there. The Dart API is
  unchanged.
* The host process is told at once when the tunnel's process is killed, rather
  than going on reporting `connected` for a tunnel that no longer exists.

## 0.4.0

* Windows support. The tunnel runs in a helper process, `vless_core.exe`,
  built from the same `vless-core` module as the Apple and Android cores, so
  one release tag pins every platform to the same Xray-core build. Packets
  reach it through a wintun adapter; addressing, routing and DNS are
  configured explicitly, because Windows has no `VpnService.Builder` or
  `NEPacketTunnelProvider` to do it.

## 0.3.3

* Pin the TLS ALPN to `http/1.1`. Xray's default offers `h2` first, and a
  supernode that accepts it makes the WebSocket upgrade impossible: TLS
  succeeds, the upgrade returns 400, and nothing is logged at warning level.
  The tunnel reported connected while carrying no traffic at all.

## 0.3.2

* Build against Flutter 3.47.9 and Dart 3.13, matching the consuming app. No
  behaviour change.

## 0.3.1

* IPv6 no longer reaches the client as "connected, then closed". The core
  drops it before its TCP stack can answer, so a browser falls back to IPv4
  instead of giving up on the site. Dual-stack pages failed only on a cold
  socket pool, which is why they broke in incognito and worked in a warm tab.
* Android is told to query a resolver inside the tunnel rather than
  `1.1.1.1`. Private DNS, opportunistic by default, was validating the
  advertised resolvers for DNS-over-TLS and then querying port 853, which no
  port-53 rule intercepts, so AAAA records reached the client anyway.

## 0.2.0

* `connect` takes an optional `dnsAddress`, which becomes the resolver that
  answers inside the tunnel. A host offering malware or adult-content
  filtering can now point the tunnel at a filtering resolver; omitting it
  keeps the previous Cloudflare pair.

## 0.1.0

* DNS no longer leaves the tunnel: the port-53 routing rule is scoped to the
  SOCKS inbound, so the built-in resolver's own upstream queries go through
  the proxy instead of a direct dial.
* A stop issued while a connect is still settling its preferences cancels it,
  rather than letting the tunnel come up afterwards.
* A label whose percent-escapes are not valid UTF-8 falls back to the raw text
  instead of rejecting the URI.

## 0.0.1

* VLESS over WebSocket + TLS on iOS and macOS, carried by a NetworkExtension
  packet tunnel provider.
* `VlessDart` API: `initialize`, `setupTunnel`, `connect`, `disconnect`,
  `isConnected`, `getVPNStatus`, `tunnelStatistics`, `statusStream`,
  `checkTunnelConfiguration`, `removeTunnelConfiguration`.
* IPv6 is captured by the tunnel so it cannot leak around it, and proxied
  rather than dropped; names resolve IPv4-only via the Xray config's
  `queryStrategy`.
* The tunnel engine lives in
  [vless-apple](https://github.com/mysteriumnetwork/vless-apple); this package
  is the control plane only.
