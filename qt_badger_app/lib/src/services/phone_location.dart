// The phone's own location, used to (a) feed the badge a position when its GPS
// has no sky, (b) show "you are here" on the map, and (c) report the phone as
// a peer. Foreground only.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class PhoneFix {
  const PhoneFix(this.lat, this.lon, this.accuracyM, this.at);
  final double lat;
  final double lon;
  final double accuracyM;
  final DateTime at;
}

class PhoneLocation {
  StreamSubscription<Position>? _sub;
  PhoneFix? last;

  /// Requests the runtime permission if needed. Returns null when it's fine, else a message to show.
  Future<String?> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return 'Location is switched off on this phone.';
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied) return 'Location permission was refused.';
      if (p == LocationPermission.deniedForever) return 'Location permission is blocked - allow it in the phone\'s app settings.';
      return null;
    } catch (e) {
      return 'Location is not available here ($e).';
    }
  }

  /// One fresh fix (also primes [last]).
  Future<PhoneFix?> current() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
      );
      return last = PhoneFix(p.latitude, p.longitude, p.accuracy, DateTime.now());
    } catch (e) {
      debugPrint('getCurrentPosition failed: $e');
      return null;
    }
  }

  bool get running => _sub != null;

  Future<void> start(void Function(PhoneFix fix) onFix) async {
    if (_sub != null) return;
    try {
      _sub = Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 2))
          .listen((p) {
            final fix = PhoneFix(p.latitude, p.longitude, p.accuracy, DateTime.now());
            last = fix;
            onFix(fix);
          }, onError: (Object e) => debugPrint('location stream error: $e'));
    } catch (e) {
      debugPrint('location stream failed: $e');
      _sub = null;
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
