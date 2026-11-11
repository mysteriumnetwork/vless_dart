// Prints the Xray config lib/src/xray_config.dart emits, with the placeholders
// the tunnel provider fills at runtime. Used to regenerate the `dartConfig`
// fixture in vless-apple's third_party/xray-mobile/xray-mobile_test.go, which
// boots the real config so a change Xray rejects fails that repo's Go suite.
//
//   fvm dart run tool/emit_cfg.dart
//
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:vless_dart/src/vless_uri.dart';
import 'package:vless_dart/src/xray_config.dart';

void main() {
  final uri = VlessUri.parse(
    'vless://f7422437-7044-4599-8165-5f7ae7311fc4@supervpn-testnet-01.mysterium.network:443'
    '?encryption=none&path=%2Fvless&security=tls&type=ws#M',
  );
  final config = XrayConfig.build(uri);

  final inbound = (config['inbounds']! as List<dynamic>).first as Map<String, dynamic>;
  inbound['port'] = 10815;
  ((inbound['settings']! as Map<String, dynamic>)['accounts']! as List<dynamic>).add(
    <String, String>{'user': 'u', 'pass': 'p'},
  );

  print(const JsonEncoder.withIndent('  ').convert(config));
}
