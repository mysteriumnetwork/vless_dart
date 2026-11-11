import 'package:vless_dart/src/vless_uri.dart';

/// Builds the Xray JSON config for a parsed [VlessUri].
///
/// The SOCKS inbound port and credentials are placeholders: the tunnel provider
/// picks a free loopback port and mints per-session credentials at startup, so
/// nothing else on the device can use the proxy.
abstract final class XrayConfig {
  static Map<String, dynamic> build(VlessUri uri) => <String, dynamic>{
    'log': <String, dynamic>{'loglevel': 'warning'},
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
          // Without routeOnly the sniffed domain replaces the target, and an
          // IPv6 literal would slip past the ::/0 routing rule below.
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
    ],
    // The tunnel captures IPv6 so it cannot leak around us, then drops it here
    // so clients fall back to IPv4. Omitting NEIPv6Settings would not disable
    // the device's physical IPv6 — it would just route it outside the tunnel.
    'routing': <String, dynamic>{
      'rules': <dynamic>[
        <String, dynamic>{
          'type': 'field',
          'ip': <dynamic>['::/0'],
          'outboundTag': 'block',
        },
      ],
    },
  };
}
