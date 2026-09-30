import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Health of the hub and the badge, plus the log of what has happened (SOS, reminders, arrivals, ...).
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  String _summary(AppState app) {
    final st = app.status;
    final b = StringBuffer('QT BADGEr app 2.0\nhub: ${app.hubLabel}  (${app.conn.name})\n');
    if (st != null) {
      b
        ..writeln(
          'badge: ${st.mcu.alive ? 'answering' : 'NOT answering'}, protocol ${st.mcu.protocol}/${st.mcu.expectedProtocol}, up ${st.mcu.uptimeS}s, restored=${st.mcu.restored}',
        )
        ..writeln(
          'hub: up ${st.hub.uptimeS}s, cpu ${st.hub.cpuTempC}C, mem ${st.hub.memUsedPct}%, disk ${st.hub.diskUsedPct}%, restores ${st.hub.restores}, llm loaded=${st.hub.llmReady}',
        )
        ..writeln('gps: ${st.gps.sourceLabel}, ${st.gps.satellites} sats')
        ..writeln('tasks ${st.tasks.length}, messages ${st.messages.length}, peers ${st.peers.length}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final scheme = Theme.of(context).colorScheme;

    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(k, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('About and diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy diagnostics',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _summary(app)));
              app.toast('Diagnostics copied');
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          const ConnectionBanner(),
          SectionCard(
            title: 'Badge',
            accent: Palette.cyan,
            child: st == null
                ? const Text('Not connected yet.')
                : Column(
                    children: [
                      row('Sketch', st.mcu.alive ? 'answering' : 'not answering'),
                      row('Protocol', '${st.mcu.protocol ?? '?'} (app expects ${st.mcu.expectedProtocol})'),
                      row('Uptime', st.mcu.uptimeS == null ? '-' : fmtDuration(st.mcu.uptimeS!)),
                      row('State restored after reset', st.mcu.restored ? 'yes' : 'not yet'),
                      row(
                        'Position',
                        st.gps.hasFix ? '${st.gps.sourceLabel}, ${st.gps.satellites} sats' : 'no fix (${st.gps.satellites} sats)',
                      ),
                      row('Screen', screenLabel(st.badge.screen)),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Hub (UNO Q, Linux side)',
            accent: Palette.cyan,
            child: st == null
                ? const Text('Not connected yet.')
                : Column(
                    children: [
                      row('Address', app.hubLabel),
                      row('Uptime', fmtDuration(st.hub.uptimeS)),
                      row('CPU temperature', st.hub.cpuTempC == null ? '-' : '${st.hub.cpuTempC} C'),
                      row('Memory used', st.hub.memUsedPct == null ? '-' : '${st.hub.memUsedPct}%'),
                      row('Disk used', st.hub.diskUsedPct == null ? '-' : '${st.hub.diskUsedPct}%'),
                      row('Times state was restored', '${st.hub.restores}'),
                      row('On-board AI model', st.hub.llmReady ? 'loaded' : 'loads on first use'),
                      row('Access key', st.authRequired ? 'required' : 'not set'),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Activity',
            accent: Palette.slate,
            child: app.eventLog.isEmpty
                ? const Text('Nothing since the app connected.')
                : Column(children: [for (final e in app.eventLog.take(30)) _EventRow(event: e)]),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'QT BADGEr app 2.0  -  talks to hub API v2 (badge protocol 4)',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});
  final BadgeEvent event;

  @override
  Widget build(BuildContext context) {
    final detail = switch (event.type) {
      'alert' =>
        '${event.source == 'app' ? 'sent from the app' : 'pressed on the badge'}${event.hasPosition ? ' at ${event.lat!.toStringAsFixed(4)}, ${event.lon!.toStringAsFixed(4)}' : ''}',
      'voice' || 'reminder' => event.text,
      'arrived' => event.data['name']?.toString() ?? '',
      'link' => event.data['mcu'] == true ? 'badge answering' : 'badge lost',
      'boot' => 'restarted, state restored',
      _ => '',
    };
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Text(DateFormat('HH:mm:ss').format(event.time), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      title: Text('${event.type}${detail.isEmpty ? '' : ': $detail'}'),
    );
  }
}
