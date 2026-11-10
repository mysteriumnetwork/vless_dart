import 'package:flutter_test/flutter_test.dart';
import 'package:vless_dart/src/vless_uri.dart';
import 'package:vless_dart/src/xray_config.dart';

const testnetUri =
    'vless://f7422437-7044-4599-8165-5f7ae7311fc4@supervpn-testnet-01.mysterium.network:443'
    '?encryption=none&host=supervpn-testnet-01.mysterium.network&path=%2Fvless'
    '&security=tls&sni=supervpn-testnet-01.mysterium.network&type=ws#Mysterium%20VLESS';

Map<String, dynamic> _build() => XrayConfig.build(VlessUri.parse(testnetUri));

void main() {
  test('builds the expected vless outbound', () {
    final outbound = (_build()['outbounds']! as List<dynamic>).first as Map<String, dynamic>;
    expect(outbound['protocol'], 'vless');

    final vnext =
        ((outbound['settings']! as Map<String, dynamic>)['vnext']! as List<dynamic>).first
            as Map<String, dynamic>;
    expect(vnext['address'], 'supervpn-testnet-01.mysterium.network');
    expect(vnext['port'], 443);

    final user = (vnext['users']! as List<dynamic>).first as Map<String, dynamic>;
    expect(user['id'], 'f7422437-7044-4599-8165-5f7ae7311fc4');
    expect(user['encryption'], 'none');
  });

  test('builds ws + tls stream settings', () {
    final outbound = (_build()['outbounds']! as List<dynamic>).first as Map<String, dynamic>;
    final stream = outbound['streamSettings']! as Map<String, dynamic>;
    expect(stream['network'], 'ws');
    expect(stream['security'], 'tls');

    final tls = stream['tlsSettings']! as Map<String, dynamic>;
    expect(tls['serverName'], 'supervpn-testnet-01.mysterium.network');
    expect(tls['allowInsecure'], false);

    final ws = stream['wsSettings']! as Map<String, dynamic>;
    expect(ws['path'], '/vless');
    expect(ws['host'], 'supervpn-testnet-01.mysterium.network');
    expect(ws.containsKey('headers'), isFalse);
  });

  test('leaves socks port and credentials for the provider to fill', () {
    final inbound = (_build()['inbounds']! as List<dynamic>).first as Map<String, dynamic>;
    expect(inbound['protocol'], 'socks');
    expect(inbound['listen'], '127.0.0.1');
    expect(inbound['port'], 0);

    final settings = inbound['settings']! as Map<String, dynamic>;
    expect(settings['accounts'], isEmpty);
    expect(settings['udp'], true);
  });

  test('includes direct and block outbounds', () {
    final tags = (_build()['outbounds']! as List<dynamic>)
        .map((dynamic o) => (o as Map<String, dynamic>)['tag'])
        .toList();
    expect(tags, <String>['proxy', 'direct', 'block']);
  });
}
