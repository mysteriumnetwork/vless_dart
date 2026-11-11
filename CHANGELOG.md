## 0.0.1

* VLESS over WebSocket + TLS on iOS and macOS, carried by a NetworkExtension
  packet tunnel provider.
* `VlessDart` API: `initialize`, `setupTunnel`, `connect`, `disconnect`,
  `isConnected`, `getVPNStatus`, `tunnelStatistics`, `statusStream`,
  `checkTunnelConfiguration`, `removeTunnelConfiguration`.
* IPv6 is captured by the tunnel and routed to a blackhole outbound, so it
  cannot leak around it.
* The Xray core ships as a checksum-verified artifact from GitHub releases;
  `LOCAL_CORE=1` links a locally built one instead.
