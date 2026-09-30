// Hand-offs to other apps: maps, the dialer and SMS. No SMS/phone permissions are
// needed - these open the phone's own apps with things pre-filled, and the person
// still taps Call / Send themselves.

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

Future<bool> _open(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('launchUrl($uri) failed: $e');
    return false;
  }
}

/// A link anyone can open in a browser or maps app.
String mapsLink(double lat, double lon) => 'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';

Future<bool> openMap(double lat, double lon, {String label = 'Badge'}) async {
  final geo = Uri(scheme: 'geo', path: '$lat,$lon', queryParameters: {'q': '$lat,$lon($label)'});
  if (!kIsWeb && await _open(geo)) return true;
  return _open(Uri.parse(mapsLink(lat, lon)));
}

Future<bool> callNumber(String phone) => _open(Uri(scheme: 'tel', path: phone));

Future<bool> textNumber(String phone, String body) => _open(Uri(scheme: 'sms', path: phone, queryParameters: {'body': body}));
