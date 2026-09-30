import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// The badge has no radio for a mesh, so peers report through the hub: other people's apps (and this one,
/// if you share your location) post positions, and the badge shows distances and buzzes when one gets close.
class PeersPage extends StatelessWidget {
  const PeersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final peers = st?.peers ?? const <PeerItem>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Peers'),
        actions: [
          IconButton(
            tooltip: 'Clear peers',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: peers.isEmpty || !app.badgeAnswering ? null : app.clearPeers,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: app.badgeAnswering ? () => _addPeer(context) : null,
        icon: const Icon(Icons.person_add),
        label: const Text('Add peer'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
        children: [
          const ConnectionBanner(),
          SectionCard(
            title: 'Share this phone',
            accent: Palette.green,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: app.settings.sharePeer,
                  onChanged: app.badgeAnswering ? (v) => app.setSharePeer(v) : null,
                  title: const Text('Report my location as a peer'),
                  subtitle: const Text('Shows up on the badge\'s Peers screen. Uses this phone\'s GPS while the app is open.'),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: app.settings.peerName,
                        maxLength: 10,
                        decoration: const InputDecoration(labelText: 'Name on the badge', counterText: ''),
                        onChanged: (v) => app.setPeerIdentity(name: v.trim()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 96,
                      child: TextFormField(
                        initialValue: '${app.settings.peerId}',
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'ID (0-255)'),
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          if (n != null && n >= 0 && n <= 255) app.setPeerIdentity(id: n);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (peers.isEmpty && st != null)
            const EmptyState(
              icon: Icons.groups_outlined,
              title: 'No peers yet',
              hint: 'When another badge or phone reports a position through this hub, it appears here and on the badge.',
            ),
          for (final p in peers)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: (p.distanceM != null && p.distanceM! < (st?.badge.peerRangeM ?? 3) ? Palette.coral : Palette.green)
                        .withValues(alpha: 0.2),
                    child: Text(p.label.isEmpty ? '?' : p.label[0].toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  title: Text(p.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${p.distanceM == null ? 'distance unknown' : fmtDistance(p.distanceM)}  -  ${fmtAgo(p.ageS)}'),
                  trailing: Text('#${p.id}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _addPeer(BuildContext context) async {
    final app = context.read<AppState>();
    final id = TextEditingController(text: '${DateTime.now().second + 1}');
    final name = TextEditingController();
    final lat = TextEditingController(text: app.phone?.lat.toStringAsFixed(6) ?? app.status?.gps.lat?.toStringAsFixed(6) ?? '');
    final lon = TextEditingController(text: app.phone?.lon.toStringAsFixed(6) ?? app.status?.gps.lon?.toStringAsFixed(6) ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Report a peer'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: id,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'ID'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: name,
                      maxLength: 10,
                      decoration: const InputDecoration(labelText: 'Name', counterText: ''),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: lat,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Latitude'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: lon,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Longitude'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Report')),
        ],
      ),
    );
    if (ok == true) {
      final la = double.tryParse(lat.text), lo = double.tryParse(lon.text), pid = int.tryParse(id.text);
      if (la == null || lo == null || pid == null) {
        app.toast('Enter a valid ID and coordinates.', error: true);
      } else {
        await app.reportPeerManually(pid, name.text.trim(), la, lo);
      }
    }
    id.dispose();
    name.dispose();
    lat.dispose();
    lon.dispose();
  }
}
