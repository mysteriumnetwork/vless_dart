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
  };
}
