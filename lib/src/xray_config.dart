import 'package:vless_dart/src/vless_uri.dart';

/// Builds the Xray JSON config for a parsed [VlessUri].
///
/// The SOCKS inbound port and credentials are placeholders: the tunnel provider
/// picks a free loopback port and mints per-session credentials at startup, so
/// nothing else on the device can use the proxy.
abstract final class XrayConfig {
  /// Resolve names to IPv4 only.
  ///
  /// The exits have no IPv6 egress, and tun2socks cannot fail an IPv6
  /// connection in a way a browser recovers from: hev completes the local TCP
  /// handshake before Xray learns the destination is unreachable, so the client
  /// sees "connected, then closed" rather than a failed connect and does not
  /// fall back to IPv4. Never offering an AAAA keeps clients off that path.
  ///
  /// Switch to `UseIP` once the exits carry IPv6.
  static const ipv4Only = 'UseIPv4';

  static Map<String, dynamic> build(VlessUri uri, {String queryStrategy = ipv4Only}) =>
      <String, dynamic>{
        'log': <String, dynamic>{'loglevel': 'warning'},
        // Answers DNS inside the tunnel so [queryStrategy] applies. Without this
        // the query goes straight to the resolver and AAAA comes back regardless.
        'dns': <String, dynamic>{
          'servers': <dynamic>['1.1.1.1', '1.0.0.1'],
          'queryStrategy': queryStrategy,
        },
        'stats': <String, dynamic>{},
        'policy': <String, dynamic>{
          'system': <String, dynamic>{'statsOutboundUplink': true, 'statsOutboundDownlink': true},
        },
        'inbounds': <dynamic>[
          <String, dynamic>{
            'tag': 'socks-in',
            'protocol': 'socks',
            'listen': '127.0.0.1',
            'port': 0,
            'settings': <String, dynamic>{'auth': 'password', 'accounts': <dynamic>[], 'udp': true},
            'sniffing': <String, dynamic>{
              'enabled': true,
              'destOverride': <dynamic>['http', 'tls'],
              // Without routeOnly the sniffed domain replaces the target, which
              // loses the address the client actually asked for.
              'routeOnly': true,
            },
          },
        ],
        'outbounds': <dynamic>[
          <String, dynamic>{
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': <String, dynamic>{
              'vnext': <dynamic>[
                <String, dynamic>{
                  'address': uri.address,
                  'port': uri.port,
                  'users': <dynamic>[
                    <String, dynamic>{'id': uri.id, 'encryption': 'none', 'level': 0},
                  ],
                },
              ],
            },
            'streamSettings': <String, dynamic>{
              'network': 'ws',
              'security': 'tls',
              'tlsSettings': <String, dynamic>{'serverName': uri.sni, 'allowInsecure': false},
              // `headers.Host` is deprecated upstream in favour of a top-level `host`.
              'wsSettings': <String, dynamic>{'path': uri.wsPath, 'host': uri.wsHost},
            },
          },
          <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
          <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
          // Hands DNS to Xray's resolver, which honours [queryStrategy]: an AAAA
          // query comes back NOERROR with no answers, so clients drop to A at once
          // instead of waiting. nonIPQuery is pinned rather than left to Xray's
          // default so it cannot change under us; it refuses HTTPS/SVCB, whose
          // ipv6hint hands clients an IPv6 address without ever asking for AAAA.
          <String, dynamic>{
            'tag': 'dns-out',
            'protocol': 'dns',
            'settings': <String, dynamic>{'nonIPQuery': 'reject'},
          },
        ],
        // IPv6 goes through the proxy, not a blackhole. Blackholing it looked
        // safe but is not: hev completes the local TCP handshake before asking
        // Xray where to route, so a dropped connection reaches the client as
        // "connected, then closed" rather than "failed". Chrome treats that as a
        // server fault and never falls back to IPv4, which breaks every
        // dual-stack site on a cold socket pool.
        'routing': <String, dynamic>{
          'rules': <dynamic>[
            // Scoped to the inbound on purpose. Unscoped, this also catches the
            // built-in resolver's own upstream queries to the servers above;
            // `dns-out` recognises those as its own and writes them straight to
            // a direct dial, so the real lookups leave in plaintext from the
            // device's own address. Restricted here, they miss every rule and
            // fall through to 'proxy' like everything else, IPv6 included.
            <String, dynamic>{
              'type': 'field',
              'inboundTag': <dynamic>['socks-in'],
              'port': 53,
              'outboundTag': 'dns-out',
            },
          ],
        },
      };
}
