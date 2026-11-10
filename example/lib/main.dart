import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vless_dart/vless_dart.dart';
import 'package:vless_dart/vpn_statistics.dart';
import 'package:vless_dart/vpn_status.dart';

/// Paste a `vless://` URI from the API here, or edit it in the field.
const _defaultUri =
    'vless://b4cadb0d-886b-47ff-9edb-1f2d01612c28@supervpn-dc-testnet-01.mysterium.network:443'
    '?encryption=none&host=supervpn-dc-testnet-01.mysterium.network&path=%2Fvless'
    '&security=tls&sni=supervpn-dc-testnet-01.mysterium.network&type=ws#Mysterium%20VLESS';

/// Connect as soon as the app is ready, so a run can be driven from the CLI.
const _autoConnect = bool.fromEnvironment('VLESS_AUTOCONNECT');

/// Each platform carries its own packet tunnel extension target.
final String _providerBundleIdentifier = Platform.isMacOS
    ? 'com.mysteriumvpn.vlessDartExample.XrayTunnelMac'
    : 'com.mysteriumvpn.vlessDartExample.XrayTunnel';
const _localizedDescription = 'Mysterium VLESS Example';

void main() => runApp(const _App());

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'VLESS Dart',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const _HomePage(),
  );
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  final VlessDart _vpn = VlessDart();
  final TextEditingController _uri = TextEditingController(text: _defaultUri);

  StreamSubscription<ConnectionStatus>? _statusSub;
  Timer? _statsTimer;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  VPNStatistics? _stats;
  String? _initError;
  bool _busy = false;
  bool _autoCheckDone = false;

  bool get _isConnected => _status == ConnectionStatus.connected;
  bool get _isTransitioning =>
      _status == ConnectionStatus.connecting || _status == ConnectionStatus.disconnecting;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _stopStatsPolling();
    _uri.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    debugPrint('[EXAMPLE] init; autoConnect=$_autoConnect provider=$_providerBundleIdentifier');
    try {
      await _vpn.initialize(
        providerBundleIdentifier: _providerBundleIdentifier,
        localizedDescription: _localizedDescription,
      );
      _statusSub = _vpn.statusStream().listen((ConnectionStatus status) {
        debugPrint('[EXAMPLE] status -> ${status.name}');
        if (!mounted) {
          return;
        }
        setState(() => _status = status);
        if (status == ConnectionStatus.connected) {
          _startStatsPolling();
          if (_autoConnect && !_autoCheckDone) {
            _autoCheckDone = true;
            unawaited(_autoCheck());
          }
        } else {
          _stopStatsPolling();
        }
      });
      final current = await _vpn.getVPNStatus();
      setState(() => _status = current);
      debugPrint('[EXAMPLE] initialize ok');
      if (_autoConnect) {
        if (current == ConnectionStatus.connected) {
          debugPrint('[EXAMPLE] already connected; skipping auto-connect');
          _startStatsPolling();
          _autoCheckDone = true;
          unawaited(_autoCheck());
        } else {
          // The tunnel takes the default route, which cuts `flutter run` off
          // from the VM service if it has not attached yet.
          await Future<void>.delayed(const Duration(seconds: 10));
          await _connect();
        }
      }
    } catch (e, stack) {
      debugPrint('[EXAMPLE] init failed: $e\n$stack');
      if (mounted) {
        setState(() => _initError = '$e');
      }
    }
  }

  void _startStatsPolling() {
    _statsTimer?.cancel();
    unawaited(_refreshStats());
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_refreshStats()));
  }

  void _stopStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  Future<void> _refreshStats() async {
    final stats = await _vpn.tunnelStatistics();
    debugPrint(
      stats == null
          ? '[EXAMPLE] stats unavailable'
          : '[EXAMPLE] stats down=${stats.totalDownload} up=${stats.totalUpload} '
                'footprint=${_formatBytes(stats.footprintBytes)}',
    );
    if (mounted) {
      setState(() => _stats = stats);
    }
  }

  Future<void> _connect() async {
    if (_isConnected) {
      _report('Already connected');
      return;
    }
    setState(() => _busy = true);
    try {
      if (!await _vpn.checkTunnelConfiguration()) {
        await _vpn.setupTunnel();
        debugPrint('[EXAMPLE] setupTunnel ok');
      }
      await _vpn.connect(_uri.text.trim());
      debugPrint('[EXAMPLE] connect requested');
    } catch (e, stack) {
      debugPrint('[EXAMPLE] connect failed: $e\n$stack');
      _report('Connect failed: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _disconnect() {
    _vpn.disconnect();
    setState(() => _stats = null);
  }

  /// Runs an action and reports its outcome, so every call is visible.
  Future<void> _run(String label, Future<Object?> Function() action) async {
    setState(() => _busy = true);
    try {
      final result = await action();
      _report('$label: ${result ?? 'ok'}');
    } catch (e) {
      _report('$label failed: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// The one check that proves traffic actually leaves through the tunnel.
  Future<String> _publicIp() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse('https://api.ipify.org?format=json'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return (jsonDecode(body) as Map<String, dynamic>)['ip'] as String;
    } finally {
      client.close(force: true);
    }
  }

  /// Pulls real traffic through the tunnel so the footprint can be read under
  /// load rather than at rest.
  Future<String> _loadTest({int megabytes = 50}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final started = DateTime.now();
    var received = 0;
    try {
      final request = await client.getUrl(
        Uri.parse('https://speed.cloudflare.com/__down?bytes=${megabytes * 1000000}'),
      );
      final response = await request.close();
      await for (final chunk in response) {
        received += chunk.length;
      }
    } finally {
      client.close(force: true);
    }
    final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
    final mbps = (received * 8 / 1000000) / (seconds == 0 ? 1 : seconds);
    return '${_formatBytes(received)} in ${seconds.toStringAsFixed(1)}s '
        '(${mbps.toStringAsFixed(1)} Mbps)';
  }

  /// One hands-free pass: where we exit, then what the tunnel costs under load.
  Future<void> _autoCheck() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    try {
      debugPrint('[EXAMPLE] exit ip: ${await _publicIp()}');
    } catch (e) {
      debugPrint('[EXAMPLE] exit ip failed: $e');
    }
    try {
      debugPrint('[EXAMPLE] load test: ${await _loadTest()}');
    } catch (e) {
      debugPrint('[EXAMPLE] load test failed: $e');
    }
  }

  void _report(String message, {bool isError = false}) {
    debugPrint('[EXAMPLE] $message');
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('VLESS Dart'), centerTitle: true),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (_initError != null) _ErrorBanner(_initError!),
        _StatusCard(status: _status, stats: _stats),
        const SizedBox(height: 16),
        TextField(
          controller: _uri,
          maxLines: 4,
          minLines: 2,
          style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
          decoration: InputDecoration(
            labelText: 'vless:// URI',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear),
              onPressed: _uri.clear,
              tooltip: 'Clear',
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 48,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _isConnected ? Theme.of(context).colorScheme.error : null,
            ),
            onPressed: _busy || _isTransitioning ? null : (_isConnected ? _disconnect : _connect),
            icon: Icon(_isConnected ? Icons.link_off : Icons.link),
            label: Text(_isConnected ? 'Disconnect' : 'Connect'),
          ),
        ),
        const SizedBox(height: 16),
        _AdvancedCard(
          busy: _busy,
          actions: <String, Future<Object?> Function()>{
            'Check tunnel config': _vpn.checkTunnelConfiguration,
            'Setup tunnel': () async {
              await _vpn.setupTunnel();
              return 'created';
            },
            'Remove tunnel': () async {
              await _vpn.removeTunnelConfiguration();
              return 'removed';
            },
            'Status': () async => (await _vpn.getVPNStatus()).name,
            'Refresh stats': () async {
              await _refreshStats();
              return _stats == null ? 'unavailable' : _formatBytes(_stats!.totalDownload);
            },
            'Public IP': _publicIp,
            'Load test (50 MB)': _loadTest,
          },
          onRun: _run,
        ),
      ],
    ),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.stats});

  final ConnectionStatus status;
  final VPNStatistics? stats;

  (Color, IconData) _appearance(ColorScheme scheme) => switch (status) {
    ConnectionStatus.connected => (Colors.green, Icons.shield),
    ConnectionStatus.connecting => (Colors.orange, Icons.sync),
    ConnectionStatus.disconnecting => (Colors.orange, Icons.sync_disabled),
    ConnectionStatus.disconnected => (scheme.outline, Icons.shield_outlined),
    ConnectionStatus.unknown => (scheme.outline, Icons.help_outline),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = _appearance(scheme);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, color: color, size: 32),
                const SizedBox(width: 12),
                Text(
                  status.name,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (stats != null) ...<Widget>[
              const Divider(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  _Counter(label: 'Downloaded', value: _formatBytes(stats!.totalDownload)),
                  _Counter(label: 'Uploaded', value: _formatBytes(stats!.totalUpload)),
                  if (stats!.footprintBytes != null)
                    _Counter(label: 'Tunnel memory', value: _formatBytes(stats!.footprintBytes)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      Text(value, style: Theme.of(context).textTheme.titleMedium),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _AdvancedCard extends StatelessWidget {
  const _AdvancedCard({required this.busy, required this.actions, required this.onRun});

  final bool busy;
  final Map<String, Future<Object?> Function()> actions;
  final Future<void> Function(String, Future<Object?> Function()) onRun;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: ExpansionTile(
      leading: const Icon(Icons.tune),
      title: const Text('Advanced'),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final entry in actions.entries)
              OutlinedButton(
                onPressed: busy ? null : () => onRun(entry.key, entry.value),
                child: Text(entry.key),
              ),
          ],
        ),
      ],
    ),
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Init error: $message', style: TextStyle(color: scheme.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}

/// Human-readable byte count (B / KB / MB / GB).
String _formatBytes(int? bytes) {
  final value = bytes ?? 0;
  const kb = 1024, mb = kb * 1024, gb = mb * 1024;
  if (value >= gb) return '${(value / gb).toStringAsFixed(2)} GB';
  if (value >= mb) return '${(value / mb).toStringAsFixed(2)} MB';
  if (value >= kb) return '${(value / kb).toStringAsFixed(1)} KB';
  return '$value B';
}
