import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vless_dart/vless_dart.dart';
import 'package:vless_dart/vpn_statistics.dart';
import 'package:vless_dart/vpn_status.dart';

/// Paste a `vless://` URI from the API here, or edit it in the field.
const _defaultUri =
    'vless://f7422437-7044-4599-8165-5f7ae7311fc4@supervpn-testnet-01.mysterium.network:443'
    '?encryption=none&host=supervpn-testnet-01.mysterium.network&path=%2Fvless'
    '&security=tls&sni=supervpn-testnet-01.mysterium.network&type=ws#Mysterium%20VLESS';

const _providerBundleIdentifier = 'com.mysteriumvpn.vlessDartExample.XrayTunnel';
const _localizedDescription = 'Mysterium VLESS Example';

void main() => runApp(const _App());

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => const MaterialApp(home: _HomePage());
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  final VlessDart _vless = VlessDart();
  final TextEditingController _uri = TextEditingController(text: _defaultUri);

  StreamSubscription<ConnectionStatus>? _statusSub;
  Timer? _statsTimer;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  VPNStatistics? _stats;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _statsTimer?.cancel();
    _uri.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await _vless.initialize(
        providerBundleIdentifier: _providerBundleIdentifier,
        localizedDescription: _localizedDescription,
      );
      _statusSub = _vless.statusStream().listen((ConnectionStatus status) {
        setState(() => _status = status);
      });
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_refreshStats()));
      await _refreshStats();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _refreshStats() async {
    final stats = await _vless.tunnelStatistics();
    if (mounted) {
      setState(() => _stats = stats);
    }
  }

  Future<void> _connect() async {
    setState(() => _error = null);
    try {
      if (!await _vless.checkTunnelConfiguration()) {
        await _vless.setupTunnel();
      }
      await _vless.connect(_uri.text);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('vless_dart example')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: <Widget>[
          TextField(
            controller: _uri,
            maxLines: 5,
            minLines: 3,
            decoration: const InputDecoration(
              labelText: 'vless:// URI',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              FilledButton(onPressed: _connect, child: const Text('Connect')),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: _vless.disconnect, child: const Text('Disconnect')),
            ],
          ),
          const SizedBox(height: 24),
          Text('Status: ${_status.name}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_stats != null)
            Text('Down: ${_stats!.totalDownload} B   Up: ${_stats!.totalUpload} B'),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    ),
  );
}
