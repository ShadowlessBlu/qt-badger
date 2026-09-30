import 'package:flutter_test/flutter_test.dart';
import 'package:qt_badger/src/services/qr_bitmap.dart';
import 'package:qt_badger/src/ui/map_page.dart';

/// Unpacks the wire format the way the badge's sketch reads it: row-major, LSB first.
List<bool> _unpack(String hex, int n) {
  final bytes = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  return [for (var bit = 0; bit < n * n; bit++) (bytes[bit >> 3] >> (bit & 7)) & 1 == 1];
}

void main() {
  group('QR bitmap for the badge', () {
    test('a short text is a version-1 (21x21) code and the hex is exactly the length the hub expects', () {
      final qr = buildQrBitmap('HELLO');
      expect(qr.size, 21);
      expect(qr.hex.length, 2 * ((21 * 21 + 7) ~/ 8)); // 56 bytes -> 112 hex chars
      expect(qr.modules.length, 21 * 21);
    });

    test('packing round-trips: what the sketch unpacks equals what we drew', () {
      for (final text in [
        'HELLO',
        'https://qtbadger.example/ama',
        meCard(name: 'Ama Mensah', phone: '+233201234567', email: 'ama@example.com', org: 'KNUST'),
      ]) {
        final qr = buildQrBitmap(text);
        expect(_unpack(qr.hex, qr.size), qr.modules, reason: text);
      }
    });

    test('the three finder patterns are in place (7 dark modules across the top rows of two corners)', () {
      final qr = buildQrBitmap('finder');
      final n = qr.size;
      for (var c = 0; c < 7; c++) {
        expect(qr.isDark(0, c), isTrue, reason: 'top-left row 0 col $c');
        expect(qr.isDark(0, n - 1 - c), isTrue, reason: 'top-right row 0 col ${n - 1 - c}');
        expect(qr.isDark(n - 1, c), isTrue, reason: 'bottom-left last row col $c');
      }
      expect(qr.isDark(1, 1), isFalse); // inside the finder ring
      expect(qr.isDark(2, 2), isTrue); // the finder's centre block
    });

    test('bit 0 of byte 0 is the top-left module (LSB first, row-major)', () {
      final qr = buildQrBitmap('lsb');
      final first = int.parse(qr.hex.substring(0, 2), radix: 16);
      expect(first & 1, qr.isDark(0, 0) ? 1 : 0);
      expect((first >> 6) & 1, qr.isDark(0, 6) ? 1 : 0);
      expect((first >> 7) & 1, qr.isDark(0, 7) ? 1 : 0);
    });

    test('anything bigger than 45x45 is refused with a useful message', () {
      expect(() => buildQrBitmap('x' * 400), throwsA(isA<QrTooLong>()));
    });

    test('a typical contact card fits the badge', () {
      final qr = buildQrBitmap(
        meCard(name: 'Ama Mensah', phone: '+233201234567', email: 'ama.mensah@example.com', url: 'https://example.com', org: 'KNUST'),
      );
      expect(qr.size, lessThanOrEqualTo(badgeMaxQrModules));
    });

    test('MeCard escapes the separator characters', () {
      expect(meCard(name: 'Doe;John'), 'MECARD:N:Doe\\;John;;');
    });
  });

  group('coordinates from what people paste', () {
    test('plain "lat, lon"', () {
      final p = parseCoordinates('6.6887, -1.6243')!;
      expect(p.latitude, 6.6887);
      expect(p.longitude, -1.6243);
    });

    test('Google Maps @ links', () {
      final p = parseCoordinates('https://www.google.com/maps/@6.688700,-1.624300,17z')!;
      expect(p.latitude, closeTo(6.6887, 1e-9));
      expect(p.longitude, closeTo(-1.6243, 1e-9));
    });

    test('OpenStreetMap mlat/mlon links', () {
      final p = parseCoordinates('https://www.openstreetmap.org/?mlat=6.6887&mlon=-1.6243#map=17/6.6887/-1.6243')!;
      expect(p.latitude, 6.6887);
      expect(p.longitude, -1.6243);
    });

    test('rejects nonsense and out-of-range values', () {
      expect(parseCoordinates('hello'), isNull);
      expect(parseCoordinates('123.4, 5'), isNull);
      expect(parseCoordinates('10, 200'), isNull);
    });
  });
}
