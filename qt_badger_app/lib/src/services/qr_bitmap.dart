// Turns text into the QR bit matrix the badge draws on its TFT.
//
// The badge stores a QR as a row-major, LSB-first bit array (bit = row * n + col,
// 1 = dark module) and can hold up to 45x45 modules (QR version 7). The hub
// checks the same length, so a mismatch is rejected there rather than drawn wrong.

import 'package:qr/qr.dart';

const int badgeMaxQrModules = 45;

class QrBitmap {
  const QrBitmap({required this.size, required this.modules, required this.hex});
  final int size;

  /// modules[row * size + col] == true is a dark module.
  final List<bool> modules;

  /// The wire format for POST /api/profile: `{"n": size, "hex": hex}`.
  final String hex;

  bool isDark(int row, int col) => modules[row * size + col];
  Map<String, dynamic> toJson() => {'n': size, 'hex': hex};
}

class QrTooLong implements Exception {
  QrTooLong(this.needed);
  final int needed;
  @override
  String toString() =>
      'That is too long for the badge\'s QR (needs a $needed x $needed code, the badge fits $badgeMaxQrModules x $badgeMaxQrModules).';
}

/// [text] -> QR at the lowest error-correction level (smallest code = biggest modules = easiest to scan off a small screen).
QrBitmap buildQrBitmap(String text, {QrErrorCorrectLevel level = QrErrorCorrectLevel.low}) {
  final QrCode code;
  try {
    code = QrCode(payload: QrPayload.fromString(text), errorCorrectLevel: level);
  } on InputTooLongException {
    throw QrTooLong(177);
  }
  if (code.moduleCount > badgeMaxQrModules) throw QrTooLong(code.moduleCount);

  final image = QrImage(code);
  final n = image.moduleCount;
  final modules = List<bool>.generate(n * n, (i) => image.isDark(i ~/ n, i % n), growable: false);
  final bytes = List<int>.filled((n * n + 7) ~/ 8, 0);
  for (var bit = 0; bit < modules.length; bit++) {
    if (modules[bit]) bytes[bit >> 3] |= 1 << (bit & 7);
  }
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return QrBitmap(size: n, modules: modules, hex: hex);
}

/// vCard-lite: "MECARD:N:Name;TEL:...;EMAIL:...;URL:...;;" - the most compact contact format phones scan natively.
String meCard({required String name, String phone = '', String email = '', String url = '', String org = ''}) {
  String esc(String s) => s.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
  final b = StringBuffer('MECARD:N:${esc(name)};');
  if (phone.isNotEmpty) b.write('TEL:${esc(phone)};');
  if (email.isNotEmpty) b.write('EMAIL:${esc(email)};');
  if (url.isNotEmpty) b.write('URL:${esc(url)};');
  if (org.isNotEmpty) b.write('ORG:${esc(org)};');
  b.write(';');
  return b.toString();
}
