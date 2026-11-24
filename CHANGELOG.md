## 0.4.0

* Windows support. The tunnel runs in a helper process, `vless_core.exe`,
  built from the same `vless-core` module as the Apple and Android cores, so
  one release tag pins every platform to the same Xray-core build. Packets
  reach it through a wintun adapter; addressing, routing and DNS are
  configured explicitly, because Windows has no `VpnService.Builder` or
  `NEPacketTunnelProvider` to do it.

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
