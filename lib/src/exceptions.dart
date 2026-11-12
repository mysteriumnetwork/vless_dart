/// The `vless://` URI could not be parsed.
class VlessUriFormatException implements Exception {
  const VlessUriFormatException(this.message);

  final String message;

  @override
  String toString() => 'VlessUriFormatException: $message';
}

/// The URI parsed, but asks for something this build does not support.
class UnsupportedVlessConfigException implements Exception {
  const UnsupportedVlessConfigException(this.message);

  final String message;

  @override
  String toString() => 'UnsupportedVlessConfigException: $message';
}
