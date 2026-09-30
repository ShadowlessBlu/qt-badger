import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// The badge has no speaker, so its Voice screen buzzes and asks this phone to read the reminder out.
class VoicePage extends StatelessWidget {
  const VoicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final open = st?.tasks.where((t) => !t.done).toList() ?? const [];
    final next = st?.nextTask;
    return Scaffold(
      appBar: AppBar(title: const Text('Voice')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          const ConnectionBanner(),
          SectionCard(
            title: 'Next reminder',
            accent: Palette.purple,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(next?.text ?? 'Nothing to say - no open tasks.', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: next == null ? null : () => app.speakOnPhone(next.text),
                      icon: const Icon(Icons.volume_up),
                      label: const Text('Speak on phone'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: app.badgeAnswering && next != null ? app.replayOnBadge : null,
                      icon: const Icon(Icons.vibration),
                      label: const Text('Replay on badge'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '"Replay on badge" does what holding button 4 on the Voice screen does: it buzzes the badge and this phone reads the reminder out.',
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Reading aloud',
            accent: Palette.purple,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: app.settings.speakVoice,
                  onChanged: (v) => app.setSetting('speakVoice', v),
                  title: const Text('Read out when the badge asks'),
                  subtitle: const Text('Voice screen replays and due reminders'),
                ),
                _Slider(
                  label: 'Speed',
                  value: app.settings.ttsRate,
                  min: 0.2,
                  max: 1.0,
                  onChanged: (v) => app.setSpeechTuning(rate: v),
                ),
                _Slider(
                  label: 'Pitch',
                  value: app.settings.ttsPitch,
                  min: 0.6,
                  max: 1.6,
                  onChanged: (v) => app.setSpeechTuning(pitch: v),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => app.speakOnPhone('This is how your badge reminders will sound.'),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Test the voice'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Open tasks',
            accent: Palette.purple,
            child: open.isEmpty
                ? const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No open tasks.'))
                : Column(
                    children: [
                      for (final t in open)
                        ListTile(
                          dense: true,
                          title: Text(t.text),
                          trailing: IconButton(icon: const Icon(Icons.volume_up_outlined), onPressed: () => app.speakOnPhone(t.text)),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => app.speakOnPhone(open.map((t) => t.text).join('. ')),
                          icon: const Icon(Icons.playlist_play),
                          label: const Text('Read them all'),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({required this.label, required this.value, required this.min, required this.max, required this.onChanged});
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 56, child: Text(label)),
      Expanded(
        child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
      ),
    ],
  );
}
