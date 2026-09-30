// HTTP client for the hub running on the UNO Q (see README: "The API").
// One method per endpoint; every failure becomes an [ApiException] with a
// message that's fit to show to the person holding the phone.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.status});
  final String message;
  final int? status;

  bool get unauthorized => status == 401;

  /// The hub answered, but the badge (the STM32 sketch) is what failed.
  bool get badgeDown => status == 503;

  @override
  String toString() => message;
}

/// Marker for "leave the QR code as it is" in [BadgeApi.setProfile] (null means "remove it").
const Object keepQr = _KeepQr();

class _KeepQr {
  const _KeepQr();
}

class BadgeApi {
  BadgeApi({required this.host, this.port = 7000, this.key = '', http.Client? client}) : _http = client ?? http.Client();

  final String host;
  final int port;
  final String key;
  final http.Client _http;

  String get baseUrl => 'http://$host:$port';

  void close() => _http.close();

  Uri _uri(String path, [Map<String, String>? query]) => Uri(scheme: 'http', host: host, port: port, path: path, queryParameters: query);

  Map<String, String> get _headers => {'Content-Type': 'application/json', if (key.isNotEmpty) 'X-Badge-Key': key};

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final uri = _uri(path, query);
    final encoded = body == null ? null : jsonEncode(body);
    final http.Response res;
    try {
      final Future<http.Response> req = switch (method) {
        'GET' => _http.get(uri, headers: _headers),
        'POST' => _http.post(uri, headers: _headers, body: encoded ?? '{}'),
        'DELETE' => _http.delete(uri, headers: _headers),
        _ => throw ArgumentError('unsupported method $method'),
      };
      res = await req.timeout(timeout);
    } on TimeoutException {
      throw ApiException("The hub at $host didn't answer in time");
    } on http.ClientException catch (e) {
      throw ApiException("Can't reach the hub at $host:$port (${_short(e.message)})");
    } on FormatException catch (e) {
      throw ApiException('Bad address: ${e.message}');
    }

    Map<String, dynamic> data = {};
    if (res.bodyBytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {
        if (res.statusCode < 400) {
          throw ApiException('The hub sent something that is not JSON - is this really the badge?', status: res.statusCode);
        }
      }
    }
    if (res.statusCode == 401) throw ApiException('The hub needs an access key (Settings > Connection)', status: 401);
    if (res.statusCode >= 400) {
      final detail = data['detail'];
      throw ApiException(detail is String ? detail : 'Request failed (${res.statusCode})', status: res.statusCode);
    }
    return data;
  }

  static String _short(String s) => s.length > 60 ? '${s.substring(0, 57)}...' : s;

  // ------------------------------------------------------------------ status
  Future<Map<String, dynamic>> health({Duration timeout = const Duration(seconds: 3)}) => _send('GET', '/api/health', timeout: timeout);

  Future<HubStatus> status() async => HubStatus.fromJson(await _send('GET', '/api/status'));

  Future<EventBatch> events(int after) async {
    final j = await _send('GET', '/api/events', query: {'after': '$after'});
    return EventBatch(
      latest: (j['latest'] as num?)?.toInt() ?? after,
      events: (j['events'] as List? ?? const []).whereType<Map>().map((e) => BadgeEvent.fromJson(e.cast<String, dynamic>())).toList(),
    );
  }

  Future<List<TrackPoint>> track() async {
    final j = await _send('GET', '/api/track');
    return (j['points'] as List? ?? const [])
        .whereType<List>()
        .where((p) => p.length >= 3)
        .map(
          (p) => TrackPoint(
            DateTime.fromMillisecondsSinceEpoch((p[0] as num).toInt() * 1000),
            (p[1] as num).toDouble(),
            (p[2] as num).toDouble(),
          ),
        )
        .toList();
  }

  // ------------------------------------------------------------------- tasks
  List<TaskItem> _tasks(Map<String, dynamic> j) =>
      (j['tasks'] as List? ?? const []).whereType<Map>().map((t) => TaskItem.fromJson(t.cast<String, dynamic>())).toList();

  Future<List<TaskItem>> addTask(String text) async => _tasks(await _send('POST', '/api/tasks', body: {'text': text}));
  Future<List<TaskItem>> toggleTask(int index) async => _tasks(await _send('POST', '/api/tasks/$index/toggle'));
  Future<List<TaskItem>> deleteTask(int index) async => _tasks(await _send('DELETE', '/api/tasks/$index'));
  Future<List<TaskItem>> clearDone() async => _tasks(await _send('POST', '/api/tasks/clear_done'));

  /// Starts a background organizer job and returns immediately; poll [organizeJob].
  Future<OrganizeJob> organize(String text, {String engine = 'auto'}) async =>
      OrganizeJob.fromJson(await _send('POST', '/api/organize', body: {'text': text, 'engine': engine, 'wait': false}));

  Future<OrganizeJob> organizeJob(String id) async => OrganizeJob.fromJson(await _send('GET', '/api/organize/$id'));

  // --------------------------------------------------------------- reminders
  Future<void> addReminder(String text, DateTime at, {bool asTask = true}) =>
      _send('POST', '/api/reminders', body: {'text': text, 'at': at.millisecondsSinceEpoch ~/ 1000, 'as_task': asTask});

  Future<void> deleteReminder(int id) => _send('DELETE', '/api/reminders/$id');

  // ---------------------------------------------------------------- controls
  Future<void> setSettings({int? backlight, bool? haptic, int? peerRangeM, int? battery, int? tzOffsetMin}) => _send(
    'POST',
    '/api/settings',
    body: {'backlight': ?backlight, 'haptic': ?haptic, 'peer_range_m': ?peerRangeM, 'battery': ?battery, 'tz_offset_min': ?tzOffsetMin},
  );

  Future<void> alert() => _send('POST', '/api/alert', timeout: const Duration(seconds: 12));
  Future<void> find({int seconds = 30}) => _send('POST', '/api/find', body: {'seconds': seconds});
  Future<void> findStop() => _send('POST', '/api/find/stop');
  Future<void> nav({String? action, String? screen}) => _send('POST', '/api/nav', body: {'action': ?action, 'screen': ?screen});

  /// Replays the current reminder on the badge (and lets the phone read it out) - or, with [text], just asks the phone to read it.
  Future<void> speak({String? text}) => _send('POST', '/api/voice/speak', body: {'text': ?text});

  // ---------------------------------------------------------------- messages
  Future<void> sendMessage(String text, {bool buzz = true, bool silent = false}) =>
      _send('POST', '/api/messages', body: {'text': text, 'buzz': buzz, 'silent': silent});

  Future<void> deleteMessage(int index) => _send('DELETE', '/api/messages/$index');
  Future<void> clearMessages() => _send('POST', '/api/messages/clear');

  // ------------------------------------------------- destination / position
  Future<void> setDestination(String name, double lat, double lon) =>
      _send('POST', '/api/destination', body: {'name': name, 'lat': lat, 'lon': lon});

  Future<void> setPosition(double lat, double lon, {int accuracy = 0}) =>
      _send('POST', '/api/position', body: {'lat': lat, 'lon': lon, 'accuracy': accuracy}, timeout: const Duration(seconds: 5));

  Future<void> reportPeer(int id, String name, double lat, double lon) =>
      _send('POST', '/api/peers/report', body: {'id': id, 'name': name, 'lat': lat, 'lon': lon}, timeout: const Duration(seconds: 5));

  Future<void> clearPeers() => _send('POST', '/api/peers/clear');

  // ---------------------------------------------------------------- name tag
  /// [qr]: [keepQr] leaves it alone, null removes it, or {'n': size, 'hex': bits} sets it.
  Future<Profile> setProfile({String? name, String? title, String? org, Object? qr = keepQr}) async {
    final j = await _send('POST', '/api/profile', body: {'name': ?name, 'title': ?title, 'org': ?org, if (qr is! _KeepQr) 'qr': qr});
    return Profile.fromJson(j);
  }
}
