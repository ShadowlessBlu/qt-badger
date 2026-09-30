// The app's brain: connection, polling, events and every action the screens can take.
//
// Polling model: GET /api/status every ~1.5 s while the app is open. The status
// carries an `event_seq`; when it moves, GET /api/events?after=<last> brings the
// new events (SOS pressed on the badge, a "read this out" request from the Voice
// screen, a due reminder, arrival at the destination). The first status after
// connecting only records the sequence number: old events aren't replayed.
//
// Every action goes through [run], so a failure - badge unreachable, list full,
// bad input - always ends up as a readable snack bar instead of a stack trace.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/badge_api.dart';
import '../api/models.dart';
import '../services/app_settings.dart';
import '../services/notifier.dart';
import '../services/phone_location.dart';
import '../services/qr_bitmap.dart';
import '../services/speech.dart';

enum Conn { connecting, online, offline, unauthorized }

class AppState extends ChangeNotifier {
  AppState(this.settings, this.messengerKey) {
    _api = _newApi();
  }

  final AppSettings settings;
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final Notifier notifier = Notifier();
  final Speech speech = Speech();
  final PhoneLocation location = PhoneLocation();

  late BadgeApi _api;
  BadgeApi get api => _api;

  HubStatus? status;
  Conn conn = Conn.connecting;
  String? connError;
  DateTime? lastOk;
  PhoneFix? phone;
  List<TrackPoint> track = const [];
  final List<BadgeEvent> eventLog = [];

  /// Set when an SOS arrives; the root widget listens and shows the alarm screen.
  final ValueNotifier<BadgeEvent?> sos = ValueNotifier(null);

  Timer? _pollTimer;
  Timer? _shareTimer;
  bool _busy = false;
  bool _again = false;
  int _fails = 0;
  int? _seq;
  bool _clockSynced = false;
  DateTime _lastPeerReport = DateTime.fromMillisecondsSinceEpoch(0);
  bool _mapVisible = false;
  bool _disposed = false;

  BadgeApi _newApi() => BadgeApi(host: settings.host, port: settings.port, key: settings.key);

  bool get online => conn == Conn.online;
  bool get badgeAnswering => online && (status?.mcu.alive ?? false);
  String get hubLabel => '${settings.host}:${settings.port}';
  ThemeMode get themeMode => switch (settings.themeMode) {
    'light' => ThemeMode.light,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark,
  };

  // --------------------------------------------------------------- lifecycle
  Future<void> start() async {
    await notifier.init();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _tick());
    _shareTimer?.cancel();
    _shareTimer = Timer.periodic(const Duration(seconds: 5), (_) => _shareTick());
    _syncLocationService();
    unawaited(_tick());
  }

  void onResume() {
    unawaited(_tick());
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _shareTimer?.cancel();
    location.stop();
    _api.close();
    sos.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // -------------------------------------------------------------- connection
  /// Saves new connection details and reconnects.
  Future<void> connect({required String host, required int port, required String key}) async {
    await settings.setConnection(host: host.trim(), port: port, key: key.trim());
    _api.close();
    _api = _newApi();
    status = null;
    _seq = null;
    _fails = 0;
    _clockSynced = false;
    conn = Conn.connecting;
    connError = null;
    _notify();
    await _tick();
  }

  /// Tries a connection without saving it. Returns null on success, else the reason.
  Future<String?> probe(String host, int port, String key) async {
    final test = BadgeApi(host: host.trim(), port: port, key: key.trim());
    try {
      final h = await test.health(timeout: const Duration(seconds: 4));
      if (h['app'] != 'QT BADGEr') return 'Something answered, but it is not the QT BADGEr hub.';
      if (h['auth_required'] == true) {
        await test.status(); // throws 401 when the key is missing or wrong
      }
      return null;
    } on ApiException catch (e) {
      return e.message;
    } finally {
      test.close();
    }
  }

  Future<void> _tick() async {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      final st = await _api.status();
      _fails = 0;
      status = st;
      conn = Conn.online;
      connError = null;
      lastOk = DateTime.now();
      if (_seq == null) {
        _seq = st.eventSeq;
        unawaited(_syncClock(st));
        unawaited(_askNotificationPermissionOnce());
      } else if (st.eventSeq < _seq!) {
        // The hub restarted: its event log (and numbering) started again, so everything in it is news.
        _seq = 0;
        await _pullEvents();
      } else if (st.eventSeq != _seq) {
        await _pullEvents();
      }
    } on ApiException catch (e) {
      _fails++;
      connError = e.message;
      if (e.unauthorized) {
        conn = Conn.unauthorized;
      } else if (_fails >= 2 || status == null) {
        conn = Conn.offline;
      }
    } catch (e) {
      _fails++;
      connError = '$e';
      if (_fails >= 2 || status == null) conn = Conn.offline;
    } finally {
      _busy = false;
    }
    _notify();
    if (_again) {
      _again = false;
      unawaited(_tick());
    }
  }

  Future<void> refresh() => _tick();

  /// Android 13+ won't show notifications until asked. Ask once, after the first good connection
  /// (not at launch, before the person has seen what the app does).
  Future<void> _askNotificationPermissionOnce() async {
    if (settings.stringOf('askedNotifications') == '1') return;
    await settings.setString('askedNotifications', '1');
    if (settings.notifications) await notifier.requestPermission();
  }

  /// The badge clock follows the phone's time zone (hub keeps UTC + an offset).
  Future<void> _syncClock(HubStatus st) async {
    if (_clockSynced) return;
    _clockSynced = true;
    final offset = DateTime.now().timeZoneOffset.inMinutes;
    if (st.mcu.alive && st.tzOffsetMin != offset) {
      try {
        await _api.setSettings(tzOffsetMin: offset);
      } catch (_) {
        _clockSynced = false; // try again on the next poll
      }
    }
  }

  // ------------------------------------------------------------------ events
  Future<void> _pullEvents() async {
    final batch = await _api.events(_seq!);
    _seq = batch.latest;
    for (final e in batch.events) {
      eventLog.insert(0, e);
      _handle(e);
    }
    if (eventLog.length > 100) eventLog.removeRange(100, eventLog.length);
  }

  void _handle(BadgeEvent e) {
    switch (e.type) {
      case 'alert':
        final where = e.hasPosition ? 'Last position ${e.lat!.toStringAsFixed(5)}, ${e.lon!.toStringAsFixed(5)}.' : 'No position fix.';
        final fromApp = e.source == 'app';
        if (settings.notifications) {
          notifier.show(
            id: 1,
            title: fromApp ? 'SOS sent' : 'SOS from the badge!',
            body: fromApp ? 'You sent an SOS from this app. $where' : 'Someone pressed SOS on the badge. $where',
            sos: true,
          );
        }
        HapticFeedback.heavyImpact();
        sos.value = e;
      case 'voice':
        if (settings.speakVoice) speech.speak(e.text, rate: settings.ttsRate, pitch: settings.ttsPitch);
      case 'reminder':
        if (settings.notifications) notifier.show(id: 2, title: 'Reminder', body: e.text);
        if (settings.speakVoice) speech.speak(e.text, rate: settings.ttsRate, pitch: settings.ttsPitch);
        toast('Reminder: ${e.text}');
      case 'arrived':
        final name = e.data['name']?.toString() ?? 'your destination';
        if (settings.notifications) notifier.show(id: 3, title: 'Arrived', body: 'You have arrived: $name');
        toast('Arrived: $name');
      case 'link':
        if (e.data['mcu'] == true) {
          toast('The badge is answering again');
        } else {
          toast('Lost contact with the badge', error: true);
        }
      case 'boot':
        toast('The badge restarted - your saved tasks and settings were restored');
    }
  }

  // ------------------------------------------------------------- UI plumbing
  void toast(String message, {bool error = false}) {
    final m = messengerKey.currentState;
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? const Color(0xFFB91C1C) : null,
        duration: Duration(seconds: error ? 5 : 3),
      ),
    );
  }

  /// Runs an API action; shows [success] or the failure as a snack bar; refreshes the status afterwards.
  Future<bool> run(Future<void> Function() action, {String? success, bool refresh = true}) async {
    try {
      await action();
      if (success != null) toast(success);
      if (refresh) unawaited(_tick());
      return true;
    } on ApiException catch (e) {
      if (e.unauthorized) {
        conn = Conn.unauthorized;
        _notify();
      }
      toast(e.message, error: true);
      return false;
    } catch (e) {
      toast('Something went wrong: $e', error: true);
      return false;
    }
  }

  // ------------------------------------------------------------------- tasks
  void _setTasks(List<TaskItem> tasks) {
    final st = status;
    if (st != null) {
      status = st.copyWith(tasks: tasks);
      _notify();
    }
  }

  Future<bool> addTask(String text) => run(() async => _setTasks(await _api.addTask(text)));
  Future<bool> toggleTask(TaskItem t) => run(() async => _setTasks(await _api.toggleTask(t.index)));
  Future<bool> deleteTask(TaskItem t) => run(() async => _setTasks(await _api.deleteTask(t.index)));
  Future<bool> clearDone() => run(() async => _setTasks(await _api.clearDone()), success: 'Completed tasks cleared');

  /// AI organizer: pushes reminders found in [text] to the badge. Reports progress while the (slow) model works.
  Future<OrganizeJob?> organize(String text, {String engine = 'auto', void Function(OrganizeJob job)? onProgress}) async {
    try {
      var job = await _api.organize(text, engine: engine);
      while (job.running) {
        onProgress?.call(job);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        job = await _api.organizeJob(job.id);
      }
      onProgress?.call(job);
      unawaited(_tick());
      return job;
    } on ApiException catch (e) {
      toast(e.message, error: true);
      return null;
    }
  }

  Future<bool> addReminder(String text, DateTime at, {bool asTask = true}) =>
      run(() => _api.addReminder(text, at, asTask: asTask), success: 'Reminder scheduled');
  Future<bool> deleteReminder(ReminderItem r) => run(() => _api.deleteReminder(r.id));

  // ---------------------------------------------------------------- messages
  Future<bool> sendMessage(String text, {bool buzz = true}) => run(() => _api.sendMessage(text, buzz: buzz), success: 'Sent to the badge');
  Future<bool> deleteMessage(MessageItem m) => run(() => _api.deleteMessage(m.index));
  Future<bool> clearMessages() => run(() => _api.clearMessages(), success: 'Inbox cleared');

  // ---------------------------------------------------------------- controls
  Future<bool> setBacklight(int v) => run(() => _api.setSettings(backlight: v), refresh: false);
  Future<bool> setHaptic(bool v) => run(() => _api.setSettings(haptic: v));
  Future<bool> setPeerRange(int m) => run(() => _api.setSettings(peerRangeM: m));
  Future<bool> setTimezoneOffset(int minutes) => run(() => _api.setSettings(tzOffsetMin: minutes), success: 'Badge clock updated');
  Future<bool> find(bool on) => run(() => on ? _api.find(seconds: 30) : _api.findStop());
  Future<bool> nav({String? action, String? screen}) => run(() => _api.nav(action: action, screen: screen));
  Future<bool> sendSos() => run(() => _api.alert(), success: 'SOS sent');

  /// Replays the current reminder on the badge; the hub then asks the phone to read it (see the 'voice' event).
  Future<bool> replayOnBadge() => run(() => _api.speak());

  // --------------------------------------------------------- map / position
  Future<bool> setDestination(String name, double lat, double lon) =>
      run(() => _api.setDestination(name, lat, lon), success: 'Destination set');

  Future<void> refreshTrack() async {
    try {
      track = await _api.track();
      _notify();
    } on ApiException {
      // the map still works without the trail
    }
  }

  void setMapVisible(bool visible) {
    _mapVisible = visible;
    _syncLocationService();
  }

  Future<void> setAssistPosition(bool on) => _setLocationFlag('assistPosition', on);
  Future<void> setSharePeer(bool on) => _setLocationFlag('sharePeer', on);

  Future<void> _setLocationFlag(String key, bool on) async {
    if (on) {
      final err = await location.ensurePermission();
      if (err != null) {
        toast(err, error: true);
        return;
      }
    }
    await settings.setBool(key, on);
    _syncLocationService();
    _notify();
  }

  void _syncLocationService() {
    final need = settings.assistPosition || settings.sharePeer || _mapVisible;
    if (need && !location.running) {
      location.start((fix) {
        phone = fix;
        _notify();
      });
    } else if (!need && location.running) {
      location.stop();
    }
  }

  /// One-off "where am I" for the map's locate button.
  Future<PhoneFix?> locateOnce() async {
    final err = await location.ensurePermission();
    if (err != null) {
      toast(err, error: true);
      return null;
    }
    final fix = await location.current();
    if (fix == null) {
      toast('Could not get a location fix yet - try near a window.', error: true);
    } else {
      phone = fix;
      _notify();
    }
    return fix;
  }

  Future<void> _shareTick() async {
    final fix = phone ?? location.last;
    if (fix == null || !online || !badgeAnswering) return;
    if (DateTime.now().difference(fix.at) > const Duration(seconds: 60)) return; // stale
    try {
      if (settings.assistPosition) {
        await _api.setPosition(fix.lat, fix.lon, accuracy: fix.accuracyM.round());
      }
      if (settings.sharePeer && DateTime.now().difference(_lastPeerReport) >= const Duration(seconds: 8)) {
        _lastPeerReport = DateTime.now();
        await _api.reportPeer(settings.peerId, settings.peerName, fix.lat, fix.lon);
      }
    } on ApiException {
      // transient; the next tick tries again
    }
  }

  // ------------------------------------------------------------------- peers
  Future<bool> reportPeerManually(int id, String name, double lat, double lon) =>
      run(() => _api.reportPeer(id, name, lat, lon), success: 'Peer reported');
  Future<bool> clearPeers() => run(() => _api.clearPeers(), success: 'Peers cleared');

  Future<void> setPeerIdentity({int? id, String? name}) async {
    await settings.setPeer(id: id, name: name);
    _notify();
  }

  // ---------------------------------------------------------------- name tag
  Future<bool> saveProfile({required String name, required String title, required String org, QrBitmap? qr, bool removeQr = false}) => run(
    () => _api.setProfile(name: name, title: title, org: org, qr: removeQr ? null : (qr?.toJson() ?? keepQr)),
    success: 'Name tag sent to the badge',
  );

  // ---------------------------------------------------------------- settings
  Future<void> setSetting(String key, bool value) async {
    await settings.setBool(key, value);
    if (key == 'notifications' && value) await notifier.requestPermission();
    _notify();
  }

  Future<void> setSpeechTuning({double? rate, double? pitch}) async {
    if (rate != null) await settings.setDouble('ttsRate', rate);
    if (pitch != null) await settings.setDouble('ttsPitch', pitch);
    _notify();
  }

  Future<void> setThemeMode(String mode) async {
    await settings.setString('themeMode', mode);
    _notify();
  }

  Future<void> setContacts(List<Contact> contacts) async {
    await settings.setContacts(contacts);
    _notify();
  }

  Future<void> speakOnPhone(String text) => speech.speak(text, rate: settings.ttsRate, pitch: settings.ttsPitch);
}
