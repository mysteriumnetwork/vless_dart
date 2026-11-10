import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vless_dart/src/exceptions.dart';
import 'package:vless_dart/vless_dart.dart';
import 'package:vless_dart/vpn_status.dart';

const testnetUri =
    'vless://f7422437-7044-4599-8165-5f7ae7311fc4@supervpn-testnet-01.mysterium.network:443'
    '?encryption=none&host=supervpn-testnet-01.mysterium.network&path=%2Fvless'
    '&security=tls&sni=supervpn-testnet-01.mysterium.network&type=ws#Mysterium%20VLESS';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('id.mysteriumvpn.vless_dart/vpncontrol');
  final calls = <MethodCall>[];

  Future<VlessDart> initialized() async {
    final vless = VlessDart();
    await vless.initialize(
      providerBundleIdentifier: 'com.example.ext',
      localizedDescription: 'Example',
    );
    return vless;
  }

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall call) async {
        calls.add(call);
        return switch (call.method) {
          'status' => 'connected',
          'checkTunnelConfiguration' => true,
          _ => null,
        };
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  test('connect sends the built Xray config, not the raw URI', () async {
    final vless = await initialized();
    await vless.connect(testnetUri);

    final connect = calls.firstWhere((MethodCall c) => c.method == 'connect');
    final raw = (connect.arguments as Map<dynamic, dynamic>)['config'] as String;
    expect(raw.contains('vless://'), isFalse);

    final config = jsonDecode(raw) as Map<String, dynamic>;
    expect(config['outbounds'], isNotNull);
    expect(config['inbounds'], isNotNull);
  });

  test('connect before initialize throws', () async {
    expect(() => VlessDart().connect(testnetUri), throwsStateError);
  });

  test('connect rejects an unsupported transport before touching the channel', () async {
    final vless = await initialized();
    await expectLater(
      vless.connect('vless://f7422437-7044-4599-8165-5f7ae7311fc4@a.com?type=grpc&security=tls'),
      throwsA(isA<UnsupportedVlessConfigException>()),
    );
    expect(calls.where((MethodCall c) => c.method == 'connect'), isEmpty);
  });

  test('getVPNStatus maps the native string', () async {
    expect(await VlessDart().getVPNStatus(), ConnectionStatus.connected);
  });

  test('checkTunnelConfiguration passes through', () async {
    expect(await VlessDart().checkTunnelConfiguration(), isTrue);
  });
}
