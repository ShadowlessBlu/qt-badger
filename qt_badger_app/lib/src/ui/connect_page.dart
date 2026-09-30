import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../services/discovery.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Where is the badge? Enter its address, or scan the network for it (handy when a phone hotspot hands out
/// a new subnet from one day to the next). Also the first screen a new install shows.
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, this.firstRun = false});
  final bool firstRun;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _key;
  bool _testing = false;
  bool _scanning = false;
  double _progress = 0;
  List<String>? _found;
  String? _result;
  bool _resultOk = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>().settings;
    _host = TextEditingController(text: s.host);
    _port = TextEditingController(text: '${s.port}');
    _key = TextEditingController(text: s.key);
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _key.dispose();
    super.dispose();
  }

  /// Accepts "192.168.1.5", "192.168.1.5:7000" and "http://harold.local:7000/".
  ({String host, int port}) _parse() {
    var h = _host.text.trim().replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/.*$'), '');
    var port = int.tryParse(_port.text.trim()) ?? defaultHubPort;
    final colon = h.lastIndexOf(':');
    if (colon > 0 && !h.contains(']')) {
      port = int.tryParse(h.substring(colon + 1)) ?? port;
      h = h.substring(0, colon);
    }
    return (host: h, port: port);
  }

  Future<void> _test() async {
    final a = _parse();
    if (a.host.isEmpty) return;
    setState(() {
      _testing = true;
      _result = null;
    });
    final err = await context.read<AppState>().probe(a.host, a.port, _key.text);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _resultOk = err == null;
      _result = err ?? 'Found the QT BADGEr hub at ${a.host}:${a.port}.';
    });
  }

  Future<void> _save() async {
    final a = _parse();
    if (a.host.isEmpty) return;
    final app = context.read<AppState>();
    await app.connect(host: a.host, port: a.port, key: _key.text);
    if (!mounted) return;
    if (!widget.firstRun && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = null;
      _progress = 0;
    });
    final hits = await scanForHubs(
      port: _parse().port,
      onProgress: (d, t) {
        if (mounted && d % 8 == 0) setState(() => _progress = d / t);
      },
    );
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _found = hits;
      if (hits.length == 1) _host.text = hits.first;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.firstRun ? 'Welcome' : 'Connection')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          if (widget.firstRun) ...[
            const SizedBox(height: 8),
            const Icon(Icons.badge, size: 64, color: Palette.cyan),
            const SizedBox(height: 12),
            const Text(
              'QT BADGEr',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              'Connect to your Arduino UNO Q badge. Your phone and the badge must be on the same Wi-Fi network (or the phone\'s hotspot).',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
          ],
          SectionCard(
            title: 'Badge address',
            accent: Palette.cyan,
            child: Column(
              children: [
                TextField(
                  controller: _host,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'IP address or name',
                    hintText: defaultHubHost,
                    prefixIcon: Icon(Icons.router),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Port'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _key,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: 'Access key (if set)', prefixIcon: Icon(Icons.key)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _testing ? null : _test,
                        icon: _testing
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.network_check),
                        label: const Text('Test'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.link),
                        label: Text(widget.firstRun ? 'Connect' : 'Save'),
                      ),
                    ),
                  ],
                ),
                if (_result != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (_resultOk ? Palette.green : Palette.coral).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_result!, style: TextStyle(color: _resultOk ? Palette.green : Palette.coral)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Find it on the network',
            accent: Palette.cyan,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  canScanNetwork
                      ? "Checks every address on the networks this phone is connected to. The badge's IP changes when a hotspot restarts, so this is the quickest fix when it stops connecting."
                      : 'Scanning needs the Android app (it is not available in a browser).',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: canScanNetwork && !_scanning ? _scan : null,
                  icon: const Icon(Icons.radar),
                  label: Text(_scanning ? 'Scanning ${(_progress * 100).round()}%' : 'Scan network'),
                ),
                if (_scanning) ...[const SizedBox(height: 10), LinearProgressIndicator(value: _progress == 0 ? null : _progress)],
                if (_found != null) ...[
                  const SizedBox(height: 12),
                  if (_found!.isEmpty)
                    const Text(
                      'No badge found. Check that the app is running on the board (App Lab > QT BADGEr _v2) and that this phone is on the same Wi-Fi.',
                    )
                  else
                    for (final ip in _found!)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.badge, color: Palette.green),
                        title: Text(ip),
                        subtitle: const Text('QT BADGEr hub'),
                        trailing: FilledButton(onPressed: () => setState(() => _host.text = ip), child: const Text('Use')),
                      ),
                ],
              ],
            ),
          ),
          if (!widget.firstRun) ...[
            const SizedBox(height: 12),
            Text(
              'Currently: ${app.hubLabel} - ${app.online ? 'connected' : (app.connError ?? 'not connected')}',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
