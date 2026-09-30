import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'about_page.dart';
import 'alert_page.dart';
import 'connect_page.dart';
import 'peers_page.dart';
import 'profile_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'voice_page.dart';

class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

    Widget tile(IconData icon, Color color, String title, String subtitle, Widget page) => Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.18),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => open(page),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          tile(
            Icons.badge,
            Palette.gold,
            'Name tag',
            st == null || st.profile.name.isEmpty
                ? 'Show your name and a QR code on the badge'
                : '${st.profile.name}${st.profile.hasQr ? '  -  with QR' : ''}',
            const ProfilePage(),
          ),
          const SizedBox(height: 8),
          tile(
            Icons.groups,
            Palette.green,
            'Peers',
            st == null ? 'Who is near the badge' : '${st.peers.length} nearby  -  share this phone as a peer',
            const PeersPage(),
          ),
          const SizedBox(height: 8),
          tile(Icons.record_voice_over, Palette.purple, 'Voice', 'Read reminders out on this phone', const VoicePage()),
          const SizedBox(height: 8),
          tile(Icons.sos, Palette.coral, 'Alert and SOS', 'Emergency contacts, alert history', const AlertPage()),
          const SizedBox(height: 8),
          tile(Icons.tune, Palette.slate, 'Settings', 'Brightness, haptics, clock, phone options', const SettingsPage()),
          const SizedBox(height: 8),
          tile(Icons.wifi_tethering, Palette.cyan, 'Connection', app.hubLabel, const ConnectPage()),
          const SizedBox(height: 8),
          tile(Icons.info_outline, Palette.slate, 'About and diagnostics', 'Hub health, activity log', const AboutPage()),
        ],
      ),
    );
  }
}
