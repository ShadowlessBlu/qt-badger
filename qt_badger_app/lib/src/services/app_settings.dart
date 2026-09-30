// Everything the app remembers between runs, in SharedPreferences.

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// The IP the badge had when this app was made; the scanner in Settings finds
/// it again when the network (a phone hotspot, say) hands out a new subnet.
const defaultHubHost = '192.168.157.74';
const defaultHubPort = 7000;

class Contact {
  const Contact({required this.name, required this.phone});
  final String name;
  final String phone;

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone};
  factory Contact.fromJson(Map<String, dynamic> j) => Contact(name: j['name']?.toString() ?? '', phone: j['phone']?.toString() ?? '');
}

class AppSettings {
  AppSettings._(this._prefs);
  final SharedPreferences _prefs;

  static Future<AppSettings> load() async {
    final s = AppSettings._(await SharedPreferences.getInstance());
    if (!s._prefs.containsKey('peerId')) {
      // Badges are numbered from 1; phones get a high id so they never collide with one.
      await s._prefs.setInt('peerId', 100 + Random().nextInt(150));
    }
    return s;
  }

  String get host => _prefs.getString('host') ?? defaultHubHost;
  int get port => _prefs.getInt('port') ?? defaultHubPort;
  String get key => _prefs.getString('key') ?? '';
  bool get configured => _prefs.getBool('configured') ?? false;

  int get peerId => _prefs.getInt('peerId') ?? 100;
  String get peerName => _prefs.getString('peerName') ?? 'Phone';

  /// Send this phone's location to the badge (it uses it whenever its own GPS has no fix).
  bool get assistPosition => _prefs.getBool('assistPosition') ?? false;

  /// Report this phone to the hub as a peer, so it shows up on the badge's Peers screen.
  bool get sharePeer => _prefs.getBool('sharePeer') ?? false;

  /// Read reminders aloud when the badge's Voice screen asks for it.
  bool get speakVoice => _prefs.getBool('speakVoice') ?? true;
  bool get notifications => _prefs.getBool('notifications') ?? true;
  double get ttsRate => _prefs.getDouble('ttsRate') ?? 0.5;
  double get ttsPitch => _prefs.getDouble('ttsPitch') ?? 1.0;

  /// 'system' | 'dark' | 'light'
  String get themeMode => _prefs.getString('themeMode') ?? 'dark';

  List<Contact> get contacts {
    final raw = _prefs.getString('contacts');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).whereType<Map>().map((m) => Contact.fromJson(m.cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> setConnection({required String host, required int port, required String key}) async {
    await _prefs.setString('host', host);
    await _prefs.setInt('port', port);
    await _prefs.setString('key', key);
    await _prefs.setBool('configured', true);
  }

  Future<void> setPeer({int? id, String? name}) async {
    if (id != null) await _prefs.setInt('peerId', id);
    if (name != null) await _prefs.setString('peerName', name);
  }

  String stringOf(String k, [String def = '']) => _prefs.getString(k) ?? def;

  Future<void> setBool(String k, bool v) => _prefs.setBool(k, v);
  Future<void> setDouble(String k, double v) => _prefs.setDouble(k, v);
  Future<void> setString(String k, String v) => _prefs.setString(k, v);

  Future<void> setContacts(List<Contact> c) => _prefs.setString('contacts', jsonEncode(c.map((e) => e.toJson()).toList()));
}
