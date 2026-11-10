import 'package:flutter_test/flutter_test.dart';
import 'package:vless_dart/vpn_status.dart';

void main() {
  test('maps known status strings', () {
    expect(ConnectionStatus.fromString('connected'), ConnectionStatus.connected);
    expect(ConnectionStatus.fromString('connecting'), ConnectionStatus.connecting);
    expect(ConnectionStatus.fromString('disconnecting'), ConnectionStatus.disconnecting);
    expect(ConnectionStatus.fromString('disconnected'), ConnectionStatus.disconnected);
  });

  test('maps anything else to unknown', () {
    expect(ConnectionStatus.fromString('wat'), ConnectionStatus.unknown);
    expect(ConnectionStatus.fromString(''), ConnectionStatus.unknown);
  });
}
