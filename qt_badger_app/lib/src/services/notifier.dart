// Local notifications for SOS, messages and reminders. Android only - on other
// platforms (desktop / web builds used for development) every call is a no-op.

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class Notifier {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> init() async {
    if (!_supported || _ready) return;
    try {
      // The status-bar icon is a white silhouette (res/drawable/ic_stat_badge.xml, protected from the release
      // build's resource shrinker by res/raw/keep.xml). If it were ever missing, fall back to the launcher icon
      // rather than losing every notification - SOS included - to an icon problem.
      try {
        await _plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_badge')));
      } catch (e) {
        debugPrint('Notifier: ic_stat_badge unavailable ($e), using the launcher icon');
        await _plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      }
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          'sos',
          'SOS alerts',
          description: 'Someone pressed SOS on the badge',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          'info',
          'Badge activity',
          description: 'Reminders, arrivals and connection changes',
          importance: Importance.high,
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('Notifier.init failed: $e');
    }
  }

  /// Asks for the Android 13+ notification permission. Returns whether it is granted.
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> show({required int id, required String title, required String body, bool sos = false}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            sos ? 'sos' : 'info',
            sos ? 'SOS alerts' : 'Badge activity',
            importance: sos ? Importance.max : Importance.high,
            priority: sos ? Priority.max : Priority.high,
            category: sos ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.message,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
      );
    } catch (e) {
      debugPrint('Notifier.show failed: $e');
    }
  }
}
