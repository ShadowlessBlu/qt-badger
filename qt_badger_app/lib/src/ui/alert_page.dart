import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../services/app_settings.dart';
import '../state/app_state.dart';
import 'launch.dart';
import 'theme.dart';
import 'widgets.dart';

/// SOS from the app, emergency contacts, and the history of alerts the badge has raised.
class AlertPage extends StatelessWidget {
  const AlertPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final contacts = app.settings.contacts;
    final alerts = app.eventLog.where((e) => e.type == 'alert').toList();
    final cooldown = st?.badge.alertCooldownMs ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Alert and SOS')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          const ConnectionBanner(),
          SectionCard(
            title: 'Send an alert',
            accent: Palette.coral,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cooldown > 0
                      ? 'An alert was just sent - wait ${(cooldown / 1000).ceil()}s before sending another.'
                      : 'Sounds the alarm on the badge and raises an alert in this app (and any other phone using this hub).',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Opacity(
                  opacity: app.badgeAnswering && cooldown == 0 ? 1 : 0.5,
                  child: IgnorePointer(
                    ignoring: !app.badgeAnswering || cooldown > 0,
                    child: HoldButton(label: 'Hold for SOS', icon: Icons.sos, onConfirmed: () => app.sendSos()),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Pressing and holding button 4 on the Alert screen of the badge does the same, and this phone gets a full-screen alarm.',
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Emergency contacts',
            accent: Palette.coral,
            trailing: TextButton.icon(
              onPressed: () => _editContact(context, null, null),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
            child: contacts.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'None yet. When an SOS arrives, this phone shows one-tap buttons to call or text these people with the badge\'s location.',
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < contacts.length; i++)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.person, color: Palette.coral),
                          title: Text(contacts[i].name),
                          subtitle: Text(contacts[i].phone),
                          onTap: () => _editContact(context, i, contacts[i]),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(icon: const Icon(Icons.call), onPressed: () => callNumber(contacts[i].phone)),
                              IconButton(icon: const Icon(Icons.sms_outlined), onPressed: () => _textWithLocation(app, contacts[i])),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Alert history',
            accent: Palette.slate,
            child: alerts.isEmpty
                ? const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('No alerts since the app connected.'))
                : Column(children: [for (final e in alerts.take(10)) _AlertTile(event: e)]),
          ),
        ],
      ),
    );
  }

  Future<void> _textWithLocation(AppState app, Contact c) async {
    final g = app.status?.gps;
    final fix = g != null && g.hasFix ? g : null;
    final where = fix != null
        ? 'My badge is at ${mapsLink(fix.lat!, fix.lon!)}'
        : app.phone != null
        ? 'I am at ${mapsLink(app.phone!.lat, app.phone!.lon)}'
        : 'I do not have a location fix right now.';
    await textNumber(c.phone, 'I need help. $where');
  }

  Future<void> _editContact(BuildContext context, int? index, Contact? existing) async {
    final app = context.read<AppState>();
    final name = TextEditingController(text: existing?.name ?? '');
    final phone = TextEditingController(text: existing?.phone ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(existing == null ? 'Add contact' : 'Edit contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number'),
            ),
          ],
        ),
        actions: [
          if (existing != null) TextButton(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Delete')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
        ],
      ),
    );
    final list = [...app.settings.contacts];
    if (result == 'save' && name.text.trim().isNotEmpty && phone.text.trim().isNotEmpty) {
      final c = Contact(name: name.text.trim(), phone: phone.text.trim());
      if (index == null) {
        list.add(c);
      } else {
        list[index] = c;
      }
      await app.setContacts(list);
    } else if (result == 'delete' && index != null) {
      list.removeAt(index);
      await app.setContacts(list);
    }
    name.dispose();
    phone.dispose();
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.event});
  final BadgeEvent event;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: Icon(event.source == 'app' ? Icons.phone_android : Icons.badge, color: Palette.coral),
    title: Text(event.source == 'app' ? 'Sent from the app' : 'Pressed on the badge'),
    subtitle: Text(
      '${DateFormat('EEE d MMM, HH:mm:ss').format(event.time)}${event.hasPosition ? '  -  ${event.lat!.toStringAsFixed(5)}, ${event.lon!.toStringAsFixed(5)}' : '  -  no position'}',
    ),
    trailing: event.hasPosition
        ? IconButton(
            icon: const Icon(Icons.map_outlined),
            onPressed: () => openMap(event.lat!, event.lon!, label: 'SOS'),
          )
        : null,
  );
}
