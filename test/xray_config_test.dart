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

  test('resolves IPv4 only, so clients never attempt IPv6', () {
    final config = _build();
    final dns = config['dns']! as Map<String, dynamic>;
    expect(dns['queryStrategy'], 'UseIPv4');

    // The strategy only applies if DNS is answered inside the tunnel, which
    // needs both the dns outbound and the rule that routes port 53 to it.
    final tags = (config['outbounds']! as List<dynamic>)
        .map((dynamic o) => (o as Map<String, dynamic>)['tag'])
        .toList();
    expect(tags, contains('dns-out'));

    final rules = (config['routing']! as Map<String, dynamic>)['rules']! as List<dynamic>;
    final dnsRule =
        rules.firstWhere((dynamic r) => (r as Map<String, dynamic>)['outboundTag'] == 'dns-out')
            as Map<String, dynamic>;
    expect(dnsRule['port'], 53);
  });

  test('the dns outbound refuses HTTPS/SVCB rather than leaving it to a default', () {
    // Pinned, not inherited: an ipv6hint in an HTTPS record hands a client an
    // IPv6 address without it ever asking for AAAA. Xray's default happens to
    // be 'reject' today, which is what we want, but it is not ours to assume.
    final outbounds = (_build()['outbounds']! as List<dynamic>).cast<Map<String, dynamic>>();
    final dnsOut = outbounds.firstWhere((o) => o['tag'] == 'dns-out');
    expect((dnsOut['settings']! as Map<String, dynamic>)['nonIPQuery'], 'reject');
    // blockTypes would answer AAAA with REFUSED instead of an empty NOERROR,
    // which some stub resolvers treat as a dead server.
    expect((dnsOut['settings']! as Map<String, dynamic>).containsKey('blockTypes'), isFalse);
  });

  test('the query strategy can be relaxed once the exits carry IPv6', () {
    final uri = VlessUri.parse(testnetUri);
    final config = XrayConfig.build(uri, queryStrategy: 'UseIP');
    expect((config['dns']! as Map<String, dynamic>)['queryStrategy'], 'UseIP');
  });

  test('sends IPv6 through the proxy rather than dropping it', () {
    final config = _build();
    final rules = (config['routing']! as Map<String, dynamic>)['rules']! as List<dynamic>;

    // A ::/0 -> block rule looks safe but breaks dual-stack clients: hev
    // completes the local TCP handshake before Xray routes, so a dropped
    // connection arrives as "connected, then closed". Chrome does not fall
    // back to IPv4 from that, so every cold dual-stack connection fails.
    expect(
      rules.where((dynamic r) => (r as Map<String, dynamic>)['outboundTag'] == 'block'),
      isEmpty,
    );
  });

  test('keeps routeOnly so the sniffed domain never replaces the target', () {
    final config = _build();
    final inbound = (config['inbounds']! as List<dynamic>).first as Map<String, dynamic>;
    expect((inbound['sniffing']! as Map<String, dynamic>)['routeOnly'], true);
  });

  test('includes the direct, block and dns outbounds', () {
    final tags = (_build()['outbounds']! as List<dynamic>)
        .map((dynamic o) => (o as Map<String, dynamic>)['tag'])
        .toList();
    // 'proxy' must stay first: Xray sends unmatched traffic to the first
    // outbound, which is what carries everything without a routing rule.
    expect(tags, <String>['proxy', 'direct', 'block', 'dns-out']);
  });
}
