/// Cumulative traffic statistics for the current VPN session.
///
/// Shape mirrors `openvpn_dart` and `wireguard_dart` so apps can present all
/// three engines uniformly. [latestHandshake] has no meaning for VLESS and is
/// always 0.
class VPNStatistics {
  const VPNStatistics({
    required this.totalDownload,
    required this.totalUpload,
    this.latestHandshake = 0,
  });

  factory VPNStatistics.fromJson(Map<String, dynamic> json) => VPNStatistics(
    totalDownload: (json['totalDownload'] as num?)?.toInt() ?? 0,
    totalUpload: (json['totalUpload'] as num?)?.toInt() ?? 0,
    latestHandshake: (json['latestHandshake'] as num?)?.toInt() ?? 0,
  );

  /// Total bytes downloaded (received) this session.
  final int totalDownload;

  /// Total bytes uploaded (sent) this session.
  final int totalUpload;

  /// Always 0 for VLESS — kept for parity with the other engines.
  final int latestHandshake;

  @override
  bool operator ==(Object other) =>
      other is VPNStatistics &&
      other.totalDownload == totalDownload &&
      other.totalUpload == totalUpload &&
      other.latestHandshake == latestHandshake;

  @override
  int get hashCode => Object.hash(totalDownload, totalUpload, latestHandshake);

  @override
  String toString() =>
      'VPNStatistics(down: $totalDownload, up: $totalUpload, handshake: $latestHandshake)';
}
