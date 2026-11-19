## 0.4.0

* Windows support. The tunnel runs in a helper process, `vless_core.exe`,
  built from the same `vless-core` module as the Apple and Android cores, so
  one release tag pins every platform to the same Xray-core build. Packets
  reach it through a wintun adapter; addressing, routing and DNS are
  configured explicitly, because Windows has no `VpnService.Builder` or
  `NEPacketTunnelProvider` to do it.

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
