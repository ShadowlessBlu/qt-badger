import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'inbox_page.dart';
import 'theme.dart';
import 'virtual_badge.dart';
import 'widgets.dart';

/// The badge tab: a live mirror of the TFT, a remote for its two buttons, quick actions and SOS.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final enabled = app.badgeAnswering;

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: app.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _Header(app: app),
            const SizedBox(height: 12),
            const ConnectionBanner(),
            VirtualBadge(status: st),
            const SizedBox(height: 14),
            _RemotePad(enabled: enabled),
            const SizedBox(height: 10),
            _ScreenChips(current: st?.badge.screen ?? 'home', enabled: enabled),
            const SizedBox(height: 14),
            _QuickActions(enabled: enabled),
            const SizedBox(height: 14),
            if (st != null) _Stats(st: st),
            const SizedBox(height: 16),
            HoldButton(label: 'Hold for SOS', icon: Icons.sos, onConfirmed: () => app.sendSos()),
            const SizedBox(height: 6),
            Center(
              child: Text(
                'Sounds the alarm on the badge and alerts this app. Hold for about a second.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final st = app.status;
    final Color c;
    final String label;
    if (app.conn == Conn.online && (st?.mcu.alive ?? false)) {
      c = Palette.green;
      label = 'Badge online';
    } else if (app.conn == Conn.online) {
      c = Palette.amber;
      label = 'Hub only';
    } else if (app.conn == Conn.connecting) {
      c = Palette.amber;
      label = 'Connecting';
    } else {
      c = Palette.danger;
      label = 'Offline';
    }
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('QT BADGEr', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
              Text(app.hubLabel, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
            ],
          ),
        ),
        Pill(label, color: c, icon: Icons.circle),
      ],
    );
  }
}

/// The badge's two buttons: short presses move, long presses select / go back.
class _RemotePad extends StatelessWidget {
  const _RemotePad({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    Widget btn(String label, IconData icon, String action, {bool primary = false}) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: (primary ? FilledButton.tonal : OutlinedButton.new)(
          onPressed: enabled ? () => app.nav(action: action) : null,
          style: ButtonStyle(minimumSize: WidgetStateProperty.all(const Size.fromHeight(52))),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              Text(label, style: const TextStyle(fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        btn('Left', Icons.chevron_left, 'left'),
        btn('Right', Icons.chevron_right, 'right'),
        btn('Select', Icons.touch_app, 'select', primary: true),
        btn('Back', Icons.undo, 'back'),
      ],
    );
  }
}

class _ScreenChips extends StatelessWidget {
  const _ScreenChips({required this.current, required this.enabled});
  final String current;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final id in screenNames)
          ChoiceChip(
            label: Text(screenLabel(id)),
            selected: id == current,
            onSelected: enabled ? (_) => app.nav(screen: id) : null,
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final finding = st?.badge.finding ?? false;
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: enabled ? () => app.find(!finding) : null,
            icon: Icon(finding ? Icons.stop_circle_outlined : Icons.volume_up),
            label: Text(finding ? 'Stop' : 'Find badge'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: enabled ? () => showComposeMessage(context) : null,
            icon: const Icon(Icons.send),
            label: const Text('Message'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: st == null || st.tasks.isEmpty
                ? null
                : () => app.speakOnPhone(st.tasks.where((t) => !t.done).map((t) => t.text).join('. ')),
            icon: const Icon(Icons.record_voice_over),
            label: const Text('Read tasks'),
          ),
        ),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.st});
  final HubStatus st;

  @override
  Widget build(BuildContext context) {
    final g = st.gps;
    final tiles = [
      StatTile(
        icon: Icons.satellite_alt,
        color: Palette.cyan,
        label: g.hasFix ? '${g.sourceLabel} - ${g.satellites} sats' : 'Position',
        value: g.hasFix ? '${g.lat!.toStringAsFixed(4)}, ${g.lon!.toStringAsFixed(4)}' : 'No fix',
      ),
      StatTile(icon: Icons.flag, color: Palette.cyan, label: st.destination.name, value: g.hasFix ? fmtDistance(g.distanceM) : '-'),
      StatTile(icon: Icons.checklist, color: Palette.amber, label: 'Tasks open', value: '${st.openTasks} of ${st.tasks.length}'),
      StatTile(icon: Icons.mail, color: Palette.sky, label: 'Unread messages', value: '${st.badge.unread}'),
      StatTile(icon: Icons.groups, color: Palette.green, label: 'Peers nearby', value: '${st.peers.length}'),
      StatTile(
        icon: Icons.thermostat,
        color: Palette.slate,
        label: 'Hub CPU',
        value: st.hub.cpuTempC == null ? '-' : '${st.hub.cpuTempC!.round()} C',
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth > 560 ? 3 : 2;
        final w = (c.maxWidth - 8 * (cols - 1)) / cols;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final t in tiles) SizedBox(width: w, child: t)],
        );
      },
    );
  }
}
