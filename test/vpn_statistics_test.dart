import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vless_dart/vless_dart.dart';
import 'package:vless_dart/vpn_statistics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('id.mysteriumvpn.vless_dart/vpncontrol');

  void reply(Future<Object?> Function() answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall call) async => call.method == 'tunnelStatistics' ? await answer() : null,
    );
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  // Each platform builds this JSON by hand, in Kotlin, Swift and C++, and the
  // three do not send the same keys. These are the strings they emit, copied
  // from the plugins: a key renamed on one side reads as zero bytes here, with
  // no error anywhere.
  group('tunnelStatistics reads what each platform sends', () {
    test('Android: both counters and a zero handshake', () async {
      reply(() async => '{"totalUpload":1024,"totalDownload":4096,"latestHandshake":0}');

      expect(
        await VlessDart().tunnelStatistics(),
        const VPNStatistics(totalUpload: 1024, totalDownload: 4096),
      );
    });

    test('Windows: the counters alone', () async {
      reply(() async => '{"totalUpload":1024,"totalDownload":4096}');

      expect(
        await VlessDart().tunnelStatistics(),
        const VPNStatistics(totalUpload: 1024, totalDownload: 4096),
      );
    });

    test('Apple: the counters and the extension footprint', () async {
      reply(() async => '{"totalUpload":1024,"totalDownload":4096,"footprintBytes":20971520}');

      expect(
        await VlessDart().tunnelStatistics(),
        const VPNStatistics(totalUpload: 1024, totalDownload: 4096, footprintBytes: 20971520),
      );
    });

    test('counters past 32 bits survive', () async {
      // A long session crosses 4 GB, and a JSON number that large is a double
      // on some decoders.
      reply(() async => '{"totalUpload":5000000000,"totalDownload":9000000000}');

      final stats = await VlessDart().tunnelStatistics();
      expect(stats?.totalUpload, 5000000000);
      expect(stats?.totalDownload, 9000000000);
    });
  });

  group('tunnelStatistics is null, never a throw, when there is nothing to read', () {
    // The app polls this once a second; a throw would be an unhandled error
    // per tick for as long as the tunnel is down.
    test('no tunnel: a null reply', () async {
      reply(() async => null);
      expect(await VlessDart().tunnelStatistics(), isNull);
    });

    test('no tunnel: an empty string', () async {
      reply(() async => '');
      expect(await VlessDart().tunnelStatistics(), isNull);
    });

    test('a reply that is not JSON', () async {
      reply(() async => 'uplink>>>12');
      expect(await VlessDart().tunnelStatistics(), isNull);
    });

    test('JSON that is not an object', () async {
      reply(() async => '[1,2]');
      expect(await VlessDart().tunnelStatistics(), isNull);
    });

    test('a platform error', () async {
      reply(() async => throw PlatformException(code: 'err_core', message: 'the core exited'));
      expect(await VlessDart().tunnelStatistics(), isNull);
    });
  });

  test('a missing counter reads as zero rather than failing the whole sample', () {
    expect(
      VPNStatistics.fromJson(const <String, dynamic>{'totalUpload': 7}),
      const VPNStatistics(totalUpload: 7, totalDownload: 0),
    );
  });
}
