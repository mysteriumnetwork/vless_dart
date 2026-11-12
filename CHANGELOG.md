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
