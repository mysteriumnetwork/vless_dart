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
    this.footprintBytes,
  });

  factory VPNStatistics.fromJson(Map<String, dynamic> json) => VPNStatistics(
    totalDownload: (json['totalDownload'] as num?)?.toInt() ?? 0,
    totalUpload: (json['totalUpload'] as num?)?.toInt() ?? 0,
    latestHandshake: (json['latestHandshake'] as num?)?.toInt() ?? 0,
    footprintBytes: (json['footprintBytes'] as num?)?.toInt(),
  );

  /// Total bytes downloaded (received) this session.
  final int totalDownload;

  /// Total bytes uploaded (sent) this session.
  final int totalUpload;

  /// Always 0 for VLESS — kept for parity with the other engines.
  final int latestHandshake;

  /// Resident footprint of the tunnel extension process, or null when
  /// unavailable. iOS jetsam-kills a Network Extension past roughly 50 MB, and
  /// the app cannot measure the extension's memory from its own process.
  final int? footprintBytes;

  @override
  bool operator ==(Object other) =>
      other is VPNStatistics &&
      other.totalDownload == totalDownload &&
      other.totalUpload == totalUpload &&
      other.latestHandshake == latestHandshake &&
      other.footprintBytes == footprintBytes;

  @override
  int get hashCode => Object.hash(totalDownload, totalUpload, latestHandshake, footprintBytes);

  @override
  String toString() =>
      'VPNStatistics(down: $totalDownload, up: $totalUpload, '
      'handshake: $latestHandshake, footprint: $footprintBytes)';
}
