import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'launch.dart';

/// Full-screen alarm shown when an SOS comes in (from the badge's button or from this app).
class SosScreen extends StatefulWidget {
  const SosScreen({super.key, required this.event});
  final BadgeEvent event;

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
    ..repeat(reverse: true);
  Timer? _buzz;

  @override
  void initState() {
    super.initState();
    HapticFeedback.vibrate();
    _buzz = Timer.periodic(const Duration(seconds: 2), (_) => HapticFeedback.vibrate());
  }

  @override
  void dispose() {
    _buzz?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final e = widget.event;
    final fromApp = e.source == 'app';
    final contacts = app.settings.contacts;
    final position = e.hasPosition ? (lat: e.lat!, lon: e.lon!) : null;
    final bodyText = position != null ? 'I need help. Location: ${mapsLink(position.lat, position.lon)}' : 'I need help.';

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) =>
          Scaffold(backgroundColor: Color.lerp(const Color(0xFF7F1D1D), const Color(0xFFB91C1C), _pulse.value), body: child),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              const Icon(Icons.sos, size: 96, color: Colors.white),
              const SizedBox(height: 12),
              Text(
                fromApp ? 'SOS sent' : 'SOS from the badge',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              Text(
                DateFormat('EEE d MMM, HH:mm:ss').format(e.time),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 20),
              if (position != null)
                Card(
                  color: Colors.black26,
                  child: ListTile(
                    leading: const Icon(Icons.place, color: Colors.white),
                    title: Text(
                      '${position.lat.toStringAsFixed(5)}, ${position.lon.toStringAsFixed(5)}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      'Last known position (${e.data['position_source'] ?? 'badge'})',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    trailing: const Icon(Icons.open_in_new, color: Colors.white),
                    onTap: () => openMap(position.lat, position.lon, label: 'SOS'),
                  ),
                )
              else
                const Card(
                  color: Colors.black26,
                  child: ListTile(
                    leading: Icon(Icons.gps_off, color: Colors.white),
                    title: Text('No position fix', style: TextStyle(color: Colors.white)),
                    subtitle: Text('The badge had no GPS or phone location at the time.', style: TextStyle(color: Colors.white70)),
                  ),
                ),
              const SizedBox(height: 8),
              for (final c in contacts.take(3)) ...[
                Card(
                  color: Colors.black26,
                  child: ListTile(
                    leading: const Icon(Icons.person, color: Colors.white),
                    title: Text(
                      c.name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(c.phone, style: const TextStyle(color: Colors.white70)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.call, color: Colors.white),
                          onPressed: () => callNumber(c.phone),
                        ),
                        IconButton(
                          icon: const Icon(Icons.sms, color: Colors.white),
                          onPressed: () => textNumber(c.phone, bodyText),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const Spacer(),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF7F1D1D),
                  minimumSize: const Size.fromHeight(56),
                ),
                icon: const Icon(Icons.check),
                label: const Text('I have seen this', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
