import 'package:vless_dart/src/exceptions.dart';

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// A parsed `vless://` share link.
///
/// Only VLESS over WebSocket + TLS is supported. Unknown query parameters are
/// ignored, but an unsupported value for `type`, `security` or `encryption`
/// throws — connecting over the wrong transport is the worse failure.
class VlessUri {
  const VlessUri({
    required this.id,
    required this.address,
    required this.port,
    required this.sni,
    required this.wsHost,
    required this.wsPath,
    this.label,
  });

  static VlessUri parse(String input) {
    final Uri uri;
    try {
      uri = Uri.parse(input.trim());
    } on FormatException catch (e) {
      throw VlessUriFormatException('not a URI: ${e.message}');
    }

    if (uri.scheme != 'vless') {
      throw VlessUriFormatException('expected scheme "vless", got "${uri.scheme}"');
    }
    final id = uri.userInfo;
    if (!_uuid.hasMatch(id)) {
      throw const VlessUriFormatException('user info is not a UUID');
    }
    if (uri.host.isEmpty) {
      throw const VlessUriFormatException('missing host');
    }

    final params = uri.queryParameters;

    final encryption = params['encryption'] ?? 'none';
    if (encryption != 'none') {
      throw UnsupportedVlessConfigException('encryption "$encryption" is not supported');
    }
    final type = params['type'];
    if (type != 'ws') {
      throw UnsupportedVlessConfigException('transport "${type ?? 'tcp'}" is not supported');
    }
    final security = params['security'];
    if (security != 'tls') {
      throw UnsupportedVlessConfigException('security "${security ?? 'none'}" is not supported');
    }

    final sni = params['sni'] ?? params['host'] ?? uri.host;
    final path = params['path'];

    return VlessUri(
      id: id,
      address: uri.host,
      port: uri.hasPort ? uri.port : 443,
      sni: sni,
      wsHost: params['host'] ?? sni,
      wsPath: path == null || path.isEmpty ? '/' : path,
      label: _decodeLabel(uri.fragment),
    );
  }

  /// `Uri.fragment` is not percent-decoded; the label is display-only, so fall
  /// back to the raw text rather than failing the whole parse.
  static String? _decodeLabel(String fragment) {
    if (fragment.isEmpty) {
      return null;
    }
    try {
      return Uri.decodeComponent(fragment);
    } on ArgumentError {
      // A malformed escape, e.g. `%ZZ` or a truncated `%`.
      return fragment;
    } on FormatException {
      // Well-formed escapes that are not valid UTF-8, e.g. `%FF`.
      return fragment;
    }
  }

  final String id;
  final String address;
  final int port;
  final String sni;
  final String wsHost;
  final String wsPath;
  final String? label;
}
