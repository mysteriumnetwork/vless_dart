import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:vless_dart/src/vless_uri.dart';
import 'package:vless_dart/src/xray_config.dart';
import 'package:vless_dart/vpn_statistics.dart';
import 'package:vless_dart/vpn_status.dart';

/// Entry point for controlling a VLESS connection.
///
/// Call [initialize] once before any other method, then [connect] / [disconnect]
/// and observe progress via [statusStream] (or poll [getVPNStatus]). Live
/// traffic counters are available from [tunnelStatistics].
///
/// Supported platforms: iOS and macOS (NetworkExtension). The API mirrors
/// `openvpn_dart` method-for-method so the two engines are interchangeable
/// behind a shared repository.
class VlessDart {
  VlessDart();

  static const String _eventChannelVpnStatus = 'id.mysteriumvpn.vless_dart/vpnstatus';
  static const String _methodChannelVpnControl = 'id.mysteriumvpn.vless_dart/vpncontrol';

  static const MethodChannel _channelControl = MethodChannel(_methodChannelVpnControl);

  static Stream<String> _vpnStatusSnapshot() =>
      const EventChannel(_eventChannelVpnStatus).receiveBroadcastStream().cast();

  /// Whether [initialize] has run.
  bool initialized = false;

  /// Prepare the plugin. Required on iOS and macOS before anything else.
  Future<void> initialize({String? providerBundleIdentifier, String? localizedDescription}) async {
    assert(
      providerBundleIdentifier != null && localizedDescription != null,
      'These values are required on iOS and macOS.',
    );

    initialized = true;
    try {
      await _channelControl.invokeMethod('initialize', <String, dynamic>{
        'providerBundleIdentifier': providerBundleIdentifier,
        'localizedDescription': localizedDescription,
      });
    } catch (e) {
      throw Exception('Failed to initialize VPN: $e');
    }
  }

  /// Connect to the VPN.
  ///
  /// [config] is the raw `vless://` URI from the API. It is parsed and turned
  /// into an Xray config here, so a malformed or unsupported URI fails before
  /// anything reaches the platform.
  ///
  /// Resolves once the tunnel has been *requested to start*, not once it is
  /// connected. Progress and failures arrive via [statusStream].
  Future<void> connect(String config) async {
    if (!initialized) {
      throw StateError('VlessDart must be initialized before connecting');
    }

    final xray = jsonEncode(XrayConfig.build(VlessUri.parse(config)));

    try {
      await _channelControl.invokeMethod('connect', <String, dynamic>{'config': xray});
    } on PlatformException catch (e) {
      throw ArgumentError('Failed to connect VPN: ${e.message}');
    }
  }

  /// Disconnect from the VPN.
  void disconnect() {
    _channelControl.invokeMethod('disconnect');
  }

  /// Whether the tunnel is currently up.
  Future<bool> isConnected() async =>
      getVPNStatus().then((ConnectionStatus value) => value == ConnectionStatus.connected);

  /// Latest connection status.
  Future<ConnectionStatus> getVPNStatus() async {
    final String? status = await _channelControl.invokeMethod('status');
    return ConnectionStatus.fromString(status ?? 'disconnected');
  }

  /// Cumulative traffic statistics for the current session.
  ///
  /// Returns null when unavailable. Counters come from the tun2socks bridge in
  /// the tunnel provider, so they measure what actually crossed the tunnel.
  Future<VPNStatistics?> tunnelStatistics() async {
    try {
      final dynamic result = await _channelControl.invokeMethod('tunnelStatistics');
      if (result is! String || result.isEmpty) {
        return null;
      }
      return VPNStatistics.fromJson(jsonDecode(result) as Map<String, dynamic>);
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Status updates for the lifetime of the connection.
  Stream<ConnectionStatus> statusStream() => _vpnStatusSnapshot()
      .asBroadcastStream()
      .distinct()
      .map((String event) => _strToStatus(event));

  /// Whether a NetworkExtension tunnel configuration already exists.
  Future<bool> checkTunnelConfiguration() async {
    try {
      final dynamic result = await _channelControl.invokeMethod('checkTunnelConfiguration');
      return result == true;
    } on PlatformException catch (e) {
      throw Exception('checkTunnelConfiguration failed: ${e.message}');
    }
  }

  /// Remove the saved NetworkExtension tunnel configuration.
  Future<void> removeTunnelConfiguration() async {
    try {
      await _channelControl.invokeMethod('removeTunnelConfiguration');
    } on PlatformException catch (e) {
      throw Exception('removeTunnelConfiguration failed: ${e.message}');
    }
  }

  /// Create the NetworkExtension tunnel configuration before connecting.
  Future<void> setupTunnel() async {
    try {
      await _channelControl.invokeMethod('setupTunnel');
    } on PlatformException catch (e) {
      throw Exception('setupTunnel failed: ${e.message}');
    }
  }

  static ConnectionStatus _strToStatus(String? status) {
    final normalized = status?.trim().toLowerCase();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized == 'idle' ||
        normalized == 'invalid') {
      return ConnectionStatus.disconnected;
    }
    return ConnectionStatus.fromString(normalized);
  }
}
