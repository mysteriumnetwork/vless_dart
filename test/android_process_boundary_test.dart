import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android runs the Xray core in its own process, `:vless`, because its Go
/// runtime cannot share one with wireguard-go's (golang/go#65050). The first
/// reference to an `XRay` class loads that runtime into whichever process made
/// it, so one stray call from the plugin's side brings the crash back: a
/// SIGSEGV with no tombstone, at some later WireGuard connect.
///
/// Nothing in a build fails when that happens, and no Android job runs here to
/// catch it on a device. These read the Kotlin sources instead.
void main() {
  const sources = 'android/src/main/kotlin/network/mysterium/vless_dart';

  /// Sources with comments removed: the docs name these classes on purpose.
  Map<String, String> kotlin() => {
    for (final file in Directory(sources).listSync().whereType<File>())
      if (file.path.endsWith('.kt'))
        file.uri.pathSegments.last: file
            .readAsStringSync()
            .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
            .replaceAll(RegExp(r'//[^\n]*'), ''),
  };

  test('only the backend touches the core', () {
    final offenders = kotlin().entries
        .where((entry) => entry.key != 'VlessBackend.kt')
        .where((entry) => RegExp(r'\bXRay\b').hasMatch(entry.value))
        .map((entry) => entry.key);

    expect(
      offenders,
      isEmpty,
      reason:
          'VlessBackend refuses to load outside :vless, which is what keeps '
          'the core out of the main process. A direct XRay reference anywhere '
          'else bypasses that guard.',
    );
  });

  test('nothing in the main process reaches the backend', () {
    const mainProcess = ['VlessDartPlugin.kt', 'VlessClient.kt', 'ConnectionStatusBroadcaster.kt'];
    final code = kotlin();

    for (final name in mainProcess) {
      expect(code, contains(name), reason: '$name moved; update this list');
      expect(
        RegExp(r'\bVlessBackend\b').hasMatch(code[name]!),
        isFalse,
        reason: '$name runs in the main process and must go through VlessClient',
      );
    }
  });

  test('the backend checks which process it is in', () {
    final backend = kotlin()['VlessBackend.kt']!;

    expect(backend, contains('check(VlessIpc.inCoreProcess())'));
  });

  test('the service runs in the process the guard expects', () {
    final manifest = File('android/src/main/AndroidManifest.xml').readAsStringSync();
    final suffix = RegExp(r'CORE_PROCESS_SUFFIX\s*=\s*"([^"]+)"')
        .firstMatch(kotlin()['VlessIpc.kt']!)
        ?.group(1);

    expect(suffix, isNotNull);
    expect(manifest, contains('android:process="$suffix"'));
  });
}
