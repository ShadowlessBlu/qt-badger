import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qt_badger/src/api/models.dart';

/// A real GET /api/status reply from the badge (trimmed only in the number of tasks/messages).
const _status = '''
{"ok":true,"time":1790195982,
 "mcu":{"alive":true,"error":"","protocol":4,"expected_protocol":4,"restored":true,"uptime_s":922},
 "badge":{"id":1,"screen":"tasks","selected_tile":3,"backlight":170,"haptic":true,"peer_range_m":3,"battery":-1,"unread":1,"finding":false,"alert":{"count":1,"cooldown_ms":0}},
 "gps":{"fix":2,"source":"phone","satellites":0,"hdop":25.5,"speed_kmh":0.0,"course":0,"age_ms":-1,"lat":6.691,"lon":-1.63,"distance_m":111.2,"bearing":180.0},
 "destination":{"name":"Test Gate","lat":6.69,"lon":-1.63},
 "tasks":[{"index":0,"text":"Meet Alex near stage B","done":false},{"index":1,"text":"Check booth 12 demo","done":true}],
 "messages":[{"index":0,"text":"Coffee at 3?","unread":true}],
 "peers":[{"id":7,"name":"Alex","lat":6.6901,"lon":-1.63005,"age_s":4,"distance_m":12.4}],
 "profile":{"name":"Ama Mensah","title":"Firmware Engineer","org":"KNUST","has_qr":true,"qr_size":25},
 "reminders":[{"id":3,"text":"Call Sam","at":1790199999,"fired":false,"as_task":true}],
 "config":{"tz_offset_min":0,"auth_required":false},
 "hub":{"cpu_temp_c":43.4,"mem_used_pct":23.4,"disk_used_pct":26.4,"hub_uptime_s":904,"host_ip":"192.168.157.74","restores":1,"llm":{"ready":false}},
 "event_seq":4}
''';

void main() {
  test('parses a real /api/status reply', () {
    final st = HubStatus.fromJson(jsonDecode(_status) as Map<String, dynamic>);
    expect(st.mcu.alive, isTrue);
    expect(st.mcu.protocolMismatch, isFalse);
    expect(st.badge.screen, 'tasks');
    expect(st.badge.selectedTile, 3);
    expect(st.badge.backlight, 170);
    expect(st.badge.unread, 1);
    expect(st.badge.alertCount, 1);
    expect(st.gps.hasFix, isTrue);
    expect(st.gps.sourceLabel, 'Phone GPS');
    expect(st.gps.distanceM, closeTo(111.2, 0.001));
    expect(st.destination.name, 'Test Gate');
    expect(st.tasks.map((t) => t.text), ['Meet Alex near stage B', 'Check booth 12 demo']);
    expect(st.openTasks, 1);
    expect(st.nextTask?.text, 'Meet Alex near stage B');
    expect(st.messages.single.unread, isTrue);
    expect(st.peers.single.label, 'Alex');
    expect(st.peers.single.distanceM, closeTo(12.4, 0.001));
    expect(st.profile.hasQr, isTrue);
    expect(st.profile.qrSize, 25);
    expect(st.reminders.single.text, 'Call Sam');
    expect(st.hub.cpuTempC, 43.4);
    expect(st.hub.hostIp, '192.168.157.74');
    expect(st.eventSeq, 4);
  });

  test('a badge with no fix and an old hub (missing fields) still parses', () {
    final st = HubStatus.fromJson({
      'mcu': {'alive': true},
      'gps': {'fix': 0, 'satellites': 3},
      'badge': {'screen': 'home'},
    });
    expect(st.gps.hasFix, isFalse);
    expect(st.gps.sourceLabel, 'No fix');
    expect(st.tasks, isEmpty);
    expect(st.destination.name, 'Destination');
    expect(st.badge.battery, -1);
    expect(st.mcu.expectedProtocol, 4);
  });

  test('flags a sketch that speaks a different protocol', () {
    final st = HubStatus.fromJson({
      'mcu': {'alive': true, 'protocol': 3, 'expected_protocol': 4},
    });
    expect(st.mcu.protocolMismatch, isTrue);
  });

  test('peer without a name is labelled by its id', () {
    expect(PeerItem.fromJson({'id': 12, 'lat': 1.0, 'lon': 2.0}).label, 'Badge 12');
  });

  test('events keep their extra fields', () {
    final e = BadgeEvent.fromJson({'seq': 9, 't': 1790195982, 'type': 'alert', 'source': 'badge', 'lat': 6.69, 'lon': -1.63});
    expect(e.type, 'alert');
    expect(e.source, 'badge');
    expect(e.hasPosition, isTrue);
    expect(e.lat, 6.69);
  });

  test('organizer job states', () {
    final running = OrganizeJob.fromJson({'job': 'ab12', 'state': 'running', 'seconds': 3.2});
    expect(running.running, isTrue);
    final done = OrganizeJob.fromJson({
      'job': 'ab12',
      'state': 'done',
      'engine': 'rules',
      'added': ['a', 'b'],
      'skipped': 1,
      'list_full': false,
    });
    expect(done.done, isTrue);
    expect(done.added, ['a', 'b']);
    expect(done.skipped, 1);
  });

  test('screen labels cover every screen the hub can report', () {
    for (final s in screenNames) {
      expect(screenLabel(s), isNot(equals(s.toLowerCase() == s && s != 'home' ? 'zzz' : '')));
    }
    expect(screenLabel('badge'), 'Name tag');
  });
}
