import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'connect_page.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  double? _dragBacklight;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  String _offsetLabel(int minutes) {
    final sign = minutes < 0 ? '-' : '+';
    final a = minutes.abs();
    return 'UTC$sign${(a ~/ 60).toString().padLeft(2, '0')}:${(a % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final enabled = app.badgeAnswering;
    final backlight = _dragBacklight ?? (st?.badge.backlight ?? 255).toDouble();
    final phoneOffset = DateTime.now().timeZoneOffset.inMinutes;
    final offsets = <int>{for (var m = -720; m <= 840; m += 30) m, st?.tzOffsetMin ?? 0}.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          const ConnectionBanner(),
          SectionCard(
            title: 'Badge',
            accent: Palette.slate,
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.brightness_6),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Slider(
                        value: backlight.clamp(12, 255),
                        min: 12,
                        max: 255,
                        label: '${(backlight * 100 / 255).round()}%',
                        onChanged: enabled
                            ? (v) {
                                setState(() => _dragBacklight = v);
                                _debounce?.cancel();
                                _debounce = Timer(const Duration(milliseconds: 250), () => app.setBacklight(v.round()));
                              }
                            : null,
                        onChangeEnd: enabled
                            ? (v) async {
                                _debounce?.cancel();
                                await app.setBacklight(v.round());
                                if (mounted) setState(() => _dragBacklight = null);
                              }
                            : null,
                      ),
                    ),
                    SizedBox(width: 44, child: Text('${(backlight * 100 / 255).round()}%', textAlign: TextAlign.end)),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: st?.badge.haptic ?? true,
                  onChanged: enabled ? app.setHaptic : null,
                  title: const Text('Haptic alerts'),
                  subtitle: const Text('Proximity buzz for peers and the buzz on new messages'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Peer alert distance'),
                  subtitle: const Text('The badge buzzes when a peer comes this close'),
                  trailing: DropdownButton<int>(
                    value: const [3, 10, 25, 50, 100].contains(st?.badge.peerRangeM) ? st!.badge.peerRangeM : 3,
                    onChanged: enabled ? (v) => app.setPeerRange(v ?? 3) : null,
                    items: [
                      for (final m in const [3, 10, 25, 50, 100]) DropdownMenuItem(value: m, child: Text('$m m')),
                    ],
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Badge clock'),
                  subtitle: Text(
                    st != null && st.tzOffsetMin == phoneOffset
                        ? 'Follows this phone (${_offsetLabel(phoneOffset)})'
                        : 'Set to ${_offsetLabel(st?.tzOffsetMin ?? 0)} - this phone is ${_offsetLabel(phoneOffset)}',
                  ),
                  trailing: st != null && st.tzOffsetMin != phoneOffset
                      ? TextButton(onPressed: enabled ? () => app.setTimezoneOffset(phoneOffset) : null, child: const Text('Use phone'))
                      : DropdownButton<int>(
                          value: st?.tzOffsetMin ?? 0,
                          onChanged: enabled ? (v) => app.setTimezoneOffset(v ?? 0) : null,
                          items: [for (final m in offsets) DropdownMenuItem(value: m, child: Text(_offsetLabel(m)))],
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'This phone',
            accent: Palette.slate,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: app.settings.assistPosition,
                  onChanged: enabled ? app.setAssistPosition : null,
                  title: const Text('Send my location to the badge'),
                  subtitle: const Text('Lets Map and Peers work indoors, where the badge has no GPS fix'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: app.settings.notifications,
                  onChanged: (v) => app.setSetting('notifications', v),
                  title: const Text('Notifications'),
                  subtitle: const Text('SOS, reminders, arrival'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: app.settings.speakVoice,
                  onChanged: (v) => app.setSetting('speakVoice', v),
                  title: const Text('Read reminders aloud'),
                  subtitle: const Text('When the badge\'s Voice screen asks, or a reminder is due'),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'dark', label: Text('Dark'), icon: Icon(Icons.dark_mode)),
                      ButtonSegment(value: 'light', label: Text('Light'), icon: Icon(Icons.light_mode)),
                      ButtonSegment(value: 'system', label: Text('System'), icon: Icon(Icons.settings_suggest)),
                    ],
                    selected: {app.settings.themeMode},
                    onSelectionChanged: (s) => app.setThemeMode(s.first),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Connection',
            accent: Palette.slate,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.wifi_tethering),
              title: Text(app.hubLabel),
              subtitle: Text(app.online ? 'Connected' : (app.connError ?? 'Not connected')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectPage())),
            ),
          ),
        ],
      ),
    );
  }
}
