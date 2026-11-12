import 'package:flutter_test/flutter_test.dart';
import 'package:vless_dart/src/exceptions.dart';
import 'package:vless_dart/src/vless_uri.dart';

const testnetUri =
    'vless://f7422437-7044-4599-8165-5f7ae7311fc4@supervpn-testnet-01.mysterium.network:443'
    '?encryption=none&host=supervpn-testnet-01.mysterium.network&path=%2Fvless'
    '&security=tls&sni=supervpn-testnet-01.mysterium.network&type=ws#Mysterium%20VLESS';

void main() {
  group('parse', () {
    test('reads every field from the testnet URI', () {
      final uri = VlessUri.parse(testnetUri);
      expect(uri.id, 'f7422437-7044-4599-8165-5f7ae7311fc4');
      expect(uri.address, 'supervpn-testnet-01.mysterium.network');
      expect(uri.port, 443);
      expect(uri.sni, 'supervpn-testnet-01.mysterium.network');
      expect(uri.wsHost, 'supervpn-testnet-01.mysterium.network');
      expect(uri.wsPath, '/vless');
      expect(uri.label, 'Mysterium VLESS');
    });

    test('falls back to the raw label rather than rejecting the URI', () {
      // %ZZ is a malformed escape (ArgumentError); %FF is a well-formed escape
      // that is not valid UTF-8 (FormatException). Neither says anything about
      // whether the connection details are usable.
      for (final fragment in <String>['bad%ZZ', 'bad%FF', 'trunc%']) {
        final uri = VlessUri.parse(
          'vless://f7422437-7044-4599-8165-5f7ae7311fc4@example.com:443'
          '?type=ws&security=tls#$fragment',
        );
        expect(uri.label, fragment);
        expect(uri.address, 'example.com');
      }
    });

    test('defaults the port to 443', () {
      final uri = VlessUri.parse(
        'vless://f7422437-7044-4599-8165-5f7ae7311fc4@example.com?type=ws&security=tls',
      );
      expect(uri.port, 443);
    });

    test('defaults the ws path to /', () {
      final uri = VlessUri.parse(
        'vless://f7422437-7044-4599-8165-5f7ae7311fc4@example.com?type=ws&security=tls',
      );
      expect(uri.wsPath, '/');
    });

    test('falls back sni -> host -> address', () {
      final noSni = VlessUri.parse(
        'vless://f7422437-7044-4599-8165-5f7ae7311fc4@example.com'
        '?type=ws&security=tls&host=cdn.example.com',
      );
      expect(noSni.sni, 'cdn.example.com');

      final neither = VlessUri.parse(
        'vless://f7422437-7044-4599-8165-5f7ae7311fc4@example.com?type=ws&security=tls',
      );
      expect(neither.sni, 'example.com');
    });

    test('ignores unknown parameters', () {
      final uri = VlessUri.parse('$testnetUri&somethingNew=42');
      expect(uri.wsPath, '/vless');
    });
  });

  group('rejects', () {
    test('a non-vless scheme', () {
      expect(() => VlessUri.parse('https://example.com'), throwsA(isA<VlessUriFormatException>()));
    });

    test('a malformed uuid', () {
      expect(
        () => VlessUri.parse('vless://not-a-uuid@example.com?type=ws&security=tls'),
        throwsA(isA<VlessUriFormatException>()),
      );
    });

    test('a missing host', () {
      expect(
        () => VlessUri.parse('vless://f7422437-7044-4599-8165-5f7ae7311fc4@?type=ws&security=tls'),
        throwsA(isA<VlessUriFormatException>()),
      );
    });

    test('an unsupported transport', () {
      expect(
        () => VlessUri.parse(
          'vless://f7422437-7044-4599-8165-5f7ae7311fc4@example.com?type=grpc&security=tls',
        ),
        throwsA(isA<UnsupportedVlessConfigException>()),
      );
    });

    test('a missing or non-tls security', () {
      expect(
        () => VlessUri.parse(
          'vless://f7422437-7044-4599-8165-5f7ae7311fc4@example.com?type=ws&security=reality',
        ),
        throwsA(isA<UnsupportedVlessConfigException>()),
      );
      expect(
        () => VlessUri.parse('vless://f7422437-7044-4599-8165-5f7ae7311fc4@example.com?type=ws'),
        throwsA(isA<UnsupportedVlessConfigException>()),
      );
    });

    test('a non-none encryption', () {
      expect(
        () => VlessUri.parse(
          'vless://f7422437-7044-4599-8165-5f7ae7311fc4@example.com'
          '?type=ws&security=tls&encryption=aes',
        ),
        throwsA(isA<UnsupportedVlessConfigException>()),
      );
    });
  });
}
