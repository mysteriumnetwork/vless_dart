import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vless_dart/vless_dart.dart';
import 'package:vless_dart/vpn_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = EventChannel('id.mysteriumvpn.vless_dart/vpnstatus');

  // One platform subscription for the whole file, because that is all VlessDart
  // ever makes: the stream is cached for the life of the isolate and stays
  // subscribed once anything has listened. A handler installed per test would
  // never be asked to listen again.
  //
  // `distinct` therefore spans tests as well: each one opens with a status
  // the one before it did not end on.
  late MockStreamHandlerEventSink platform;
  var listens = 0;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          listens++;
          platform = events;
        },
      ),
    );
  });

  /// Everything the stream delivers while [send] runs, errors included.
  Future<List<Object>> deliveredWhile(void Function() send) async {
    final seen = <Object>[];
    final subscription = VlessDart().statusStream().listen(seen.add, onError: seen.add);
    // The listen call has to reach the platform before it has a sink to use.
    await pumpEventQueue();
    send();
    await pumpEventQueue();
    await subscription.cancel();
    return seen;
  }

  test('maps the native strings, in order', () async {
    final seen = await deliveredWhile(() {
      platform
        ..success('connecting')
        ..success('connected')
        ..success('disconnecting')
        ..success('disconnected');
    });

    expect(seen, <ConnectionStatus>[
      ConnectionStatus.connecting,
      ConnectionStatus.connected,
      ConnectionStatus.disconnecting,
      ConnectionStatus.disconnected,
    ]);
  });

  test('a repeated status is delivered once', () async {
    // Android re-announces its status to a plugin that has just bound, and
    // Windows replays it to a new listener. Neither is a transition.
    final seen = await deliveredWhile(() {
      platform
        ..success('connecting')
        ..success('connecting')
        ..success('connected')
        ..success('connected');
    });

    expect(seen, <ConnectionStatus>[ConnectionStatus.connecting, ConnectionStatus.connected]);
  });

  test("Apple's idle states read as disconnected, as getVPNStatus reads them", () async {
    final seen = await deliveredWhile(() {
      platform
        ..success('invalid')
        ..success('connecting')
        ..success('idle')
        // Already disconnected once normalised, so not a second event.
        ..success('disconnected');
    });

    expect(seen, <ConnectionStatus>[
      ConnectionStatus.disconnected,
      ConnectionStatus.connecting,
      ConnectionStatus.disconnected,
    ]);
  });

  test('a name this version does not know is unknown, not a crash', () async {
    final seen = await deliveredWhile(() => platform.success('reasserting'));

    expect(seen, <ConnectionStatus>[ConnectionStatus.unknown]);
  });

  test('a failure the platform reports on the stream reaches the listener', () async {
    // On Windows this is the only route a connect failure has: connect()
    // resolves once the start is requested, and the reason follows here.
    final seen = await deliveredWhile(() {
      platform
        ..success('connecting')
        ..error(code: 'core_error', message: 'start xray: boom')
        ..success('disconnected');
    });

    expect(seen, hasLength(3));
    expect(seen[0], ConnectionStatus.connecting);
    expect(
      seen[1],
      isA<PlatformException>()
          .having((e) => e.code, 'code', 'core_error')
          .having((e) => e.message, 'message', 'start xray: boom'),
    );
    expect(seen[2], ConnectionStatus.disconnected);
  });

  test('every listener shares the one platform subscription', () async {
    // receiveBroadcastStream() re-registers the channel's handler on each
    // call, so a second subscription would silently end the first one's
    // events. Five tests have listened and cancelled by now.
    await deliveredWhile(() => platform.success('connected'));

    expect(listens, 1);
  });
}
