// Plain data classes for what the hub's JSON API returns (python/main.py on the
// board). Parsing is deliberately forgiving: a field the hub doesn't send yet
// (older/newer hub) falls back to a default instead of throwing, so the app
// still connects and shows what it can.

double? _d(Object? v) => v is num ? v.toDouble() : null;
int _i(Object? v, [int def = 0]) => v is num ? v.toInt() : def;
String _s(Object? v, [String def = '']) => v == null ? def : v.toString();
bool _b(Object? v, [bool def = false]) => v is bool ? v : (v is num ? v != 0 : def);
Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
List<Map<String, dynamic>> _l(Object? v) => v is List ? v.map(_m).toList() : <Map<String, dynamic>>[];

const screenNames = ['home', 'map', 'peers', 'tasks', 'voice', 'alert', 'settings', 'badge', 'inbox'];

String screenLabel(String id) => switch (id) {
  'home' => 'Home',
  'map' => 'Map',
  'peers' => 'Peers',
  'tasks' => 'Tasks',
  'voice' => 'Voice',
  'alert' => 'Alert',
  'settings' => 'Settings',
  'badge' => 'Name tag',
  'inbox' => 'Inbox',
  _ => id,
};

class TaskItem {
  const TaskItem({required this.index, required this.text, required this.done});
  final int index;
  final String text;
  final bool done;

  factory TaskItem.fromJson(Map<String, dynamic> j) => TaskItem(index: _i(j['index']), text: _s(j['text']), done: _b(j['done']));
}

class MessageItem {
  const MessageItem({required this.index, required this.text, required this.unread});
  final int index;
  final String text;
  final bool unread;

  factory MessageItem.fromJson(Map<String, dynamic> j) => MessageItem(index: _i(j['index']), text: _s(j['text']), unread: _b(j['unread']));
}

class PeerItem {
  const PeerItem({required this.id, required this.name, required this.lat, required this.lon, required this.ageS, this.distanceM});
  final int id;
  final String name;
  final double lat;
  final double lon;
  final int ageS;
  final double? distanceM;

  String get label => name.isNotEmpty ? name : 'Badge $id';

  factory PeerItem.fromJson(Map<String, dynamic> j) => PeerItem(
    id: _i(j['id']),
    name: _s(j['name']),
    lat: _d(j['lat']) ?? 0,
    lon: _d(j['lon']) ?? 0,
    ageS: _i(j['age_s']),
    distanceM: _d(j['distance_m']),
  );
}

class ReminderItem {
  const ReminderItem({required this.id, required this.text, required this.at, required this.asTask});
  final int id;
  final String text;
  final DateTime at;
  final bool asTask;

  factory ReminderItem.fromJson(Map<String, dynamic> j) => ReminderItem(
    id: _i(j['id']),
    text: _s(j['text']),
    at: DateTime.fromMillisecondsSinceEpoch(_i(j['at']) * 1000),
    asTask: _b(j['as_task'], true),
  );
}

class Destination {
  const Destination({required this.name, required this.lat, required this.lon});
  final String name;
  final double lat;
  final double lon;

  factory Destination.fromJson(Map<String, dynamic> j) =>
      Destination(name: _s(j['name'], 'Destination'), lat: _d(j['lat']) ?? 0, lon: _d(j['lon']) ?? 0);
}

class Profile {
  const Profile({this.name = '', this.title = '', this.org = '', this.hasQr = false, this.qrSize = 0});
  final String name;
  final String title;
  final String org;
  final bool hasQr;
  final int qrSize;

  factory Profile.fromJson(Map<String, dynamic> j) =>
      Profile(name: _s(j['name']), title: _s(j['title']), org: _s(j['org']), hasQr: _b(j['has_qr']), qrSize: _i(j['qr_size']));
}

class GpsInfo {
  const GpsInfo({
    this.fix = 0,
    this.source = 'none',
    this.satellites = 0,
    this.hdop,
    this.speedKmh,
    this.course,
    this.ageMs,
    this.lat,
    this.lon,
    this.distanceM,
    this.bearing,
  });

  /// 0 = no position, 1 = the badge's own GPS, 2 = the phone's location.
  final int fix;
  final String source;
  final int satellites;
  final double? hdop;
  final double? speedKmh;
  final double? course;
  final int? ageMs;
  final double? lat;
  final double? lon;
  final double? distanceM;
  final double? bearing;

  bool get hasFix => fix != 0 && lat != null && lon != null;
  String get sourceLabel => switch (fix) {
    1 => 'Badge GPS',
    2 => 'Phone GPS',
    _ => 'No fix',
  };

  factory GpsInfo.fromJson(Map<String, dynamic> j) => GpsInfo(
    fix: _i(j['fix']),
    source: _s(j['source'], 'none'),
    satellites: _i(j['satellites']),
    hdop: _d(j['hdop']),
    speedKmh: _d(j['speed_kmh']),
    course: _d(j['course']),
    ageMs: j['age_ms'] is num ? _i(j['age_ms']) : null,
    lat: _d(j['lat']),
    lon: _d(j['lon']),
    distanceM: _d(j['distance_m']),
    bearing: _d(j['bearing']),
  );
}

class BadgeInfo {
  const BadgeInfo({
    this.id = 1,
    this.screen = 'home',
    this.selectedTile = 1,
    this.backlight = 255,
    this.haptic = true,
    this.peerRangeM = 3,
    this.battery = -1,
    this.unread = 0,
    this.finding = false,
    this.alertCount = 0,
    this.alertCooldownMs = 0,
  });
  final int id;
  final String screen;
  final int selectedTile;
  final int backlight;
  final bool haptic;
  final int peerRangeM;
  final int battery;
  final int unread;
  final bool finding;
  final int alertCount;
  final int alertCooldownMs;

  factory BadgeInfo.fromJson(Map<String, dynamic> j) {
    final alert = _m(j['alert']);
    return BadgeInfo(
      id: _i(j['id'], 1),
      screen: _s(j['screen'], 'home'),
      selectedTile: _i(j['selected_tile'], 1),
      backlight: _i(j['backlight'], 255),
      haptic: _b(j['haptic'], true),
      peerRangeM: _i(j['peer_range_m'], 3),
      battery: _i(j['battery'], -1),
      unread: _i(j['unread']),
      finding: _b(j['finding']),
      alertCount: _i(alert['count']),
      alertCooldownMs: _i(alert['cooldown_ms']),
    );
  }
}

class McuInfo {
  const McuInfo({this.alive = false, this.error = '', this.protocol, this.expectedProtocol = 4, this.restored = false, this.uptimeS});
  final bool alive;
  final String error;
  final int? protocol;
  final int expectedProtocol;
  final bool restored;
  final int? uptimeS;

  bool get protocolMismatch => protocol != null && protocol != expectedProtocol;

  factory McuInfo.fromJson(Map<String, dynamic> j) => McuInfo(
    alive: _b(j['alive']),
    error: _s(j['error']),
    protocol: j['protocol'] is num ? _i(j['protocol']) : null,
    expectedProtocol: _i(j['expected_protocol'], 4),
    restored: _b(j['restored']),
    uptimeS: j['uptime_s'] is num ? _i(j['uptime_s']) : null,
  );
}

class HubInfo {
  const HubInfo({
    this.cpuTempC,
    this.memUsedPct,
    this.diskUsedPct,
    this.uptimeS = 0,
    this.hostIp = '',
    this.restores = 0,
    this.llmReady = false,
  });
  final double? cpuTempC;
  final double? memUsedPct;
  final double? diskUsedPct;
  final int uptimeS;
  final String hostIp;
  final int restores;
  final bool llmReady;

  factory HubInfo.fromJson(Map<String, dynamic> j) => HubInfo(
    cpuTempC: _d(j['cpu_temp_c']),
    memUsedPct: _d(j['mem_used_pct']),
    diskUsedPct: _d(j['disk_used_pct']),
    uptimeS: _i(j['hub_uptime_s']),
    hostIp: _s(j['host_ip']),
    restores: _i(j['restores']),
    llmReady: _b(_m(j['llm'])['ready']),
  );
}

/// Everything GET /api/status returns.
class HubStatus {
  const HubStatus({
    required this.time,
    required this.mcu,
    required this.badge,
    required this.gps,
    required this.destination,
    required this.tasks,
    required this.messages,
    required this.peers,
    required this.profile,
    required this.reminders,
    required this.hub,
    required this.tzOffsetMin,
    required this.authRequired,
    required this.eventSeq,
  });

  final int time;
  final McuInfo mcu;
  final BadgeInfo badge;
  final GpsInfo gps;
  final Destination destination;
  final List<TaskItem> tasks;
  final List<MessageItem> messages;
  final List<PeerItem> peers;
  final Profile profile;
  final List<ReminderItem> reminders;
  final HubInfo hub;
  final int tzOffsetMin;
  final bool authRequired;
  final int eventSeq;

  /// A copy with some lists swapped - used to show the result of an action instantly, before the next poll confirms it.
  HubStatus copyWith({List<TaskItem>? tasks, List<MessageItem>? messages}) => HubStatus(
    time: time,
    mcu: mcu,
    badge: badge,
    gps: gps,
    destination: destination,
    tasks: tasks ?? this.tasks,
    messages: messages ?? this.messages,
    peers: peers,
    profile: profile,
    reminders: reminders,
    hub: hub,
    tzOffsetMin: tzOffsetMin,
    authRequired: authRequired,
    eventSeq: eventSeq,
  );

  int get openTasks => tasks.where((t) => !t.done).length;
  TaskItem? get nextTask {
    for (final t in tasks) {
      if (!t.done) return t;
    }
    return null;
  }

  factory HubStatus.fromJson(Map<String, dynamic> j) {
    final cfg = _m(j['config']);
    return HubStatus(
      time: _i(j['time']),
      mcu: McuInfo.fromJson(_m(j['mcu'])),
      badge: BadgeInfo.fromJson(_m(j['badge'])),
      gps: GpsInfo.fromJson(_m(j['gps'])),
      destination: Destination.fromJson(_m(j['destination'])),
      tasks: _l(j['tasks']).map(TaskItem.fromJson).toList(),
      messages: _l(j['messages']).map(MessageItem.fromJson).toList(),
      peers: _l(j['peers']).map(PeerItem.fromJson).toList(),
      profile: Profile.fromJson(_m(j['profile'])),
      reminders: _l(j['reminders']).map(ReminderItem.fromJson).toList(),
      hub: HubInfo.fromJson(_m(j['hub'])),
      tzOffsetMin: _i(cfg['tz_offset_min']),
      authRequired: _b(cfg['auth_required']),
      eventSeq: _i(j['event_seq']),
    );
  }
}

/// One entry of the hub's event log (SOS, voice replay, reminder, arrival, ...).
class BadgeEvent {
  const BadgeEvent({required this.seq, required this.time, required this.type, required this.data});
  final int seq;
  final DateTime time;
  final String type;
  final Map<String, dynamic> data;

  String get text => _s(data['text']);
  String get source => _s(data['source']);
  double? get lat => _d(data['lat']);
  double? get lon => _d(data['lon']);
  bool get hasPosition => lat != null && lon != null;

  factory BadgeEvent.fromJson(Map<String, dynamic> j) =>
      BadgeEvent(seq: _i(j['seq']), time: DateTime.fromMillisecondsSinceEpoch(_i(j['t']) * 1000), type: _s(j['type']), data: j);
}

class EventBatch {
  const EventBatch({required this.latest, required this.events});
  final int latest;
  final List<BadgeEvent> events;
}

/// A background AI-organizer request (POST /api/organize with wait: false).
class OrganizeJob {
  const OrganizeJob({
    required this.id,
    required this.state,
    this.engine,
    this.added = const [],
    this.skipped = 0,
    this.listFull = false,
    this.error,
    this.seconds = 0,
  });
  final String id;
  final String state; // running | done | error
  final String? engine;
  final List<String> added;
  final int skipped;
  final bool listFull;
  final String? error;
  final double seconds;

  bool get running => state == 'running';
  bool get done => state == 'done';

  factory OrganizeJob.fromJson(Map<String, dynamic> j) => OrganizeJob(
    id: _s(j['job']),
    state: _s(j['state'], 'running'),
    engine: j['engine'] == null ? null : _s(j['engine']),
    added: (j['added'] is List) ? (j['added'] as List).map((e) => e.toString()).toList() : const [],
    skipped: _i(j['skipped']),
    listFull: _b(j['list_full']),
    error: j['error'] == null ? null : _s(j['error']),
    seconds: _d(j['seconds']) ?? 0,
  );
}

class TrackPoint {
  const TrackPoint(this.time, this.lat, this.lon);
  final DateTime time;
  final double lat;
  final double lon;
}
