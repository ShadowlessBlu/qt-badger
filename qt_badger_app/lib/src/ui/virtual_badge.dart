// A live mirror of the badge's 320x172 TFT.
//
// It isn't a screenshot (the STM32 draws straight to the panel and has no frame
// buffer to read back): the app redraws each screen from the hub's status using
// the same coordinates, colours and layout as sketch/sketch.ino, so what you see
// here is what the badge is showing - the home grid with the highlighted tile,
// the Map arrow, the task list, and so on.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';

/// RGB565 (what the TFT uses) -> Flutter colour.
Color rgb565(int v) => Color.fromARGB(255, ((v >> 11) & 31) * 255 ~/ 31, ((v >> 5) & 63) * 255 ~/ 63, (v & 31) * 255 ~/ 31);

final _bg = Colors.black;
const _text = Colors.white;
final _dim = rgb565(0x39C7);
final _accent = rgb565(0x07FF);
final _heart = rgb565(0xF800);
final _good = rgb565(0x07E0);
final _amber = rgb565(0xFD20);
final _purple = rgb565(0x780F);
final _coral = rgb565(0xFA45);
final _gold = rgb565(0xFEA0);
final _sky = rgb565(0x5D9F);

class _Tile {
  const _Tile(this.x, this.y, this.label, this.color);
  final double x, y;
  final String label;
  final Color color;
}

List<_Tile> get _tiles => [
  _Tile(8, 30, 'Map', _accent),
  _Tile(88, 30, 'Peers', _good),
  _Tile(168, 30, 'Tasks', _amber),
  _Tile(248, 30, 'Voice', _purple),
  _Tile(8, 100, 'Alert', _coral),
  _Tile(88, 100, 'Settings', _dim),
  _Tile(168, 100, 'Badge', _gold),
  _Tile(248, 100, 'Inbox', _sky),
];

class VirtualBadge extends StatelessWidget {
  const VirtualBadge({super.key, required this.status});
  final HubStatus? status;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 320 / 172,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24, width: 3),
          boxShadow: [BoxShadow(color: _accent.withValues(alpha: 0.18), blurRadius: 24)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: status == null
              ? const ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Text('waiting for the badge...', style: TextStyle(color: Colors.white54)),
                  ),
                )
              : CustomPaint(painter: _BadgePainter(status!), size: Size.infinite),
        ),
      ),
    );
  }
}

class _BadgePainter extends CustomPainter {
  _BadgePainter(this.st);
  final HubStatus st;

  late Canvas _c;

  @override
  void paint(Canvas canvas, Size size) {
    _c = canvas;
    canvas.save();
    canvas.scale(size.width / 320, size.height / 172);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 320, 172), Paint()..color = _bg);
    _statusBar();
    switch (st.badge.screen) {
      case 'map':
        _map();
      case 'peers':
        _peers();
      case 'tasks':
        _tasks();
      case 'voice':
        _voice();
      case 'alert':
        _alert();
      case 'settings':
        _settings();
      case 'badge':
        _badge();
      case 'inbox':
        _inbox();
      default:
        _home();
    }
    canvas.restore();
  }

  // ----------------------------------------------------------------- helpers
  void _txt(String s, double x, double y, {int size = 1, Color color = _text, FontWeight? weight}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: size == 1 ? 9.5 : 9.5 * size * 0.92,
          fontFamily: 'monospace',
          fontWeight: weight ?? (size > 1 ? FontWeight.w700 : FontWeight.w500),
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    tp.paint(_c, Offset(x, y));
  }

  void _fillRRect(double x, double y, double w, double h, double r, Color color) =>
      _c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)), Paint()..color = color);

  void _strokeRRect(double x, double y, double w, double h, double r, Color color, {double width = 1}) => _c.drawRRect(
    RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)),
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width,
  );

  void _line(double x1, double y1, double x2, double y2, Color color) => _c.drawLine(
    Offset(x1, y1),
    Offset(x2, y2),
    Paint()
      ..color = color
      ..strokeWidth = 1.2,
  );

  void _circle(double x, double y, double r, Color color, {bool fill = true}) => _c.drawCircle(
    Offset(x, y),
    r,
    Paint()
      ..color = color
      ..style = fill ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 1.2,
  );

  void _tri(Offset a, Offset b, Offset c, Color color, {bool fill = true}) => _c.drawPath(
    Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy)
      ..lineTo(c.dx, c.dy)
      ..close(),
    Paint()
      ..color = color
      ..style = fill ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 1.2,
  );

  void _title(String s, Color color) => _txt(s, 8, 28, size: 2, color: color);

  void _backHint() => _txt('hold 6 = back', 6, 160, color: _dim);

  // -------------------------------------------------------------- status bar
  void _statusBar() {
    _c.drawLine(const Offset(0, 22), const Offset(320, 22), Paint()..color = _dim);
    _txt('Badge #${st.badge.id}', 6, 6);
    final local = DateTime.now().toUtc().add(Duration(minutes: st.tzOffsetMin));
    _txt('${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}', 70, 6);
    for (final (x, d) in [(150.0, '6'), (170.0, '4')]) {
      _fillRRect(x, 4, 14, 14, 3, _dim);
      _txt(d, x + 4, 7);
    }
    if (st.badge.unread > 0) {
      _c.drawRect(
        const Rect.fromLTWH(196, 6, 14, 10),
        Paint()
          ..color = _sky
          ..style = PaintingStyle.stroke,
      );
      _line(196, 6, 203, 11, _sky);
      _line(210, 6, 203, 11, _sky);
      _txt('${st.badge.unread}', 214, 7, color: _sky);
    }
    _circle(270, 11, 3, st.mcu.alive ? _good : _dim);
    _strokeRRect(280, 5, 28, 12, 2, _text);
    _c.drawRect(const Rect.fromLTWH(309, 8, 2, 6), Paint()..color = _text);
    final bat = st.badge.battery;
    if (bat >= 0) {
      _c.drawRect(Rect.fromLTWH(282, 7, 24 * bat.clamp(0, 100) / 100, 8), Paint()..color = bat < 20 ? _heart : _good);
    } else {
      _txt('?', 291, 7, color: _dim);
    }
  }

  // -------------------------------------------------------------------- home
  void _home() {
    for (var i = 0; i < _tiles.length; i++) {
      final t = _tiles[i];
      final sel = i + 1 == st.badge.selectedTile;
      _fillRRect(t.x, t.y, 72, 62, 8, sel ? t.color : _dim);
      _tileIcon(i, t.x + 36, t.y + 31 - 6, sel ? _bg : _text);
      _txt(t.label, t.x + (72 - t.label.length * 5.9) / 2, t.y + 48, color: sel ? _bg : _text);
    }
  }

  void _tileIcon(int i, double cx, double cy, Color c) {
    switch (i) {
      case 0:
        _circle(cx, cy - 4, 6, c);
        _tri(Offset(cx - 6, cy), Offset(cx + 6, cy), Offset(cx, cy + 10), c);
      case 1:
        _circle(cx - 5, cy, 5, c);
        _circle(cx + 5, cy, 5, c);
      case 2:
        _strokeRRect(cx - 8, cy - 8, 16, 16, 3, c);
        _line(cx - 4, cy, cx - 1, cy + 4, c);
        _line(cx - 1, cy + 4, cx + 5, cy - 5, c);
      case 3:
        _fillRRect(cx - 4, cy - 9, 8, 14, 4, c);
        _line(cx, cy + 6, cx, cy + 10, c);
        _line(cx - 5, cy + 10, cx + 5, cy + 10, c);
      case 4:
        _tri(Offset(cx, cy - 9), Offset(cx - 9, cy + 7), Offset(cx + 9, cy + 7), c, fill: false);
        _line(cx, cy - 2, cx, cy + 1, c);
        _c.drawCircle(Offset(cx, cy + 4), 0.8, Paint()..color = c);
      case 5:
        _circle(cx, cy, 7, c, fill: false);
        _circle(cx, cy, 2, c, fill: false);
      case 6:
        _strokeRRect(cx - 9, cy - 7, 18, 16, 2, c);
        _c.drawRect(Rect.fromLTWH(cx - 3, cy - 10, 6, 3), Paint()..color = c);
        _circle(cx - 4, cy - 2, 2, c, fill: false);
        _line(cx - 6, cy + 3, cx + 6, cy + 3, c);
        _line(cx - 6, cy + 6, cx + 2, cy + 6, c);
      case 7:
        _c.drawRect(
          Rect.fromLTWH(cx - 9, cy - 6, 18, 13),
          Paint()
            ..color = c
            ..style = PaintingStyle.stroke,
        );
        _line(cx - 9, cy - 6, cx, cy + 2, c);
        _line(cx + 9, cy - 6, cx, cy + 2, c);
    }
  }

  // --------------------------------------------------------------------- map
  void _map() {
    final g = st.gps;
    _title(st.destination.name, _accent);
    if (!g.hasFix) {
      _txt('SEARCHING for GPS fix...', 8, 55, color: _heart);
      _txt('satellites: ${g.satellites}', 8, 70, color: _dim);
      _txt("or send your phone's location", 8, 84, color: _dim);
      _txt('from the app (Map > Use phone GPS)', 8, 96, color: _dim);
      _backHint();
      return;
    }
    final dist = g.distanceM ?? 0;
    final brg = g.bearing ?? 0;
    _circle(240, 95, 42, _dim, fill: false);
    _navArrow(240, 95, 32, brg, _accent);
    _txt(dist < 1000 ? '${dist.round()}m' : '${(dist / 1000).toStringAsFixed(2)}km', 8, 55, size: 2);
    _txt('bearing ${brg.round()} deg', 8, 78, color: _dim);
    _txt('hdg: from North', 8, 92, color: _dim);
    _txt(g.fix == 1 ? 'pos: badge GPS' : 'pos: phone GPS', 8, 106, color: _dim);
    _backHint();
  }

  void _navArrow(double cx, double cy, double size, double deg, Color color) {
    final rad = deg * math.pi / 180;
    final tip = Offset(cx + size * math.sin(rad), cy - size * math.cos(rad));
    final b1 = rad + 135 * math.pi / 180, b2 = rad - 135 * math.pi / 180;
    _tri(
      tip,
      Offset(cx + size * 0.5 * math.sin(b1), cy - size * 0.5 * math.cos(b1)),
      Offset(cx + size * 0.5 * math.sin(b2), cy - size * 0.5 * math.cos(b2)),
      color,
    );
  }

  // ------------------------------------------------------------------- peers
  void _peers() {
    _title('Peers', _good);
    if (st.peers.isEmpty) {
      _txt('No peers yet - other badges and', 8, 60, color: _dim);
      _txt('phones report in through the hub', 8, 74, color: _dim);
    } else if (!st.gps.hasFix) {
      _txt('Waiting for your own position', 8, 60, color: _dim);
    } else {
      var y = 50.0;
      for (final p in st.peers.take(6)) {
        final d = p.distanceM ?? 0;
        final stale = p.ageS > 120;
        final near = d < st.badge.peerRangeM;
        _txt(
          '${p.label} - ${d < 1000 ? '${d.round()} m' : '${(d / 1000).toStringAsFixed(1)} km'}${p.ageS > 9 ? '  (${p.ageS}s)' : ''}',
          12,
          y,
          color: stale ? _dim : (near ? _heart : _text),
        );
        y += 18;
      }
    }
    _backHint();
  }

  // ------------------------------------------------------------------- tasks
  void _tasks() {
    _title('Tasks', _amber);
    if (st.tasks.isEmpty) {
      _txt('No reminders from the hub yet', 8, 60, color: _dim);
    } else {
      _txt('${st.openTasks} open of ${st.tasks.length}', 80, 36, color: _dim);
      var y = 50.0;
      for (final t in st.tasks.take(6)) {
        _c.drawRect(
          Rect.fromLTWH(12, y, 10, 10),
          Paint()
            ..color = _dim
            ..style = PaintingStyle.stroke,
        );
        if (t.done) _c.drawRect(Rect.fromLTWH(14, y + 2, 6, 6), Paint()..color = _amber);
        final text = t.text.length > 34 ? '${t.text.substring(0, 32)}..' : t.text;
        _txt(text, 28, y, color: t.done ? _dim : _text);
        y += 18;
      }
    }
    _txt('6/4 browse  hold 4: check off, then clear', 8, 148, color: _dim);
    _backHint();
  }

  // ------------------------------------------------------------------- voice
  void _voice() {
    _title('Voice', _purple);
    _txt('would speak:', 8, 55, color: _dim);
    final next = st.nextTask?.text ?? 'no reminder right now';
    _txt(next.length > 34 ? '${next.substring(0, 32)}..' : next, 8, 70);
    _txt('hold 4: replay - buzzes here,', 8, 92, color: _dim);
    _txt(st.mcu.alive ? 'and the phone app reads it out' : 'no hub link: buzz only', 8, 106, color: _dim);
    _backHint();
  }

  // ------------------------------------------------------------------- alert
  void _alert() {
    _title('Alert', _coral);
    if (st.badge.alertCooldownMs > 0) {
      _fillRRect(6, 52, 220, 24, 4, _heart);
      _txt('ALERT SENT - phone app notified', 14, 58);
    } else {
      _txt('hold 4 to send an alert', 8, 60, color: _dim);
      _txt('hub link ok: the app gets it', 8, 74, color: _dim);
    }
    _backHint();
  }

  // ---------------------------------------------------------------- settings
  void _settings() {
    _title('Settings', _text);
    final rows = [
      ('Brightness', '${(st.badge.backlight * 100 / 255).floor()}%'),
      ('Haptic alerts', st.badge.haptic ? 'On' : 'Off'),
      ('Peer alert', '${st.badge.peerRangeM} m'),
    ];
    var y = 55.0;
    for (final (label, value) in rows) {
      _txt(label, 12, y, color: _dim);
      _txt(value, 140, y, color: _accent);
      y += 26;
    }
    _txt('6/4 browse   hold 4: change value', 8, 148, color: _dim);
    _backHint();
  }

  // ------------------------------------------------------------------- badge
  void _badge() {
    final p = st.profile;
    if (p.name.isEmpty) {
      _txt('No name set yet.', 8, 60, color: _dim);
      _txt('Set it in the app: Badge tab.', 8, 74, color: _dim);
      _txt('Badge', 8, 100, size: 3, color: _gold);
    } else {
      final width = p.hasQr ? 185.0 : 304.0;
      final nameSize = p.name.length * 18 <= width ? 3 : (p.name.length * 12 <= width ? 2 : 1);
      _txt(p.name, 8, 44, size: nameSize);
      var y = 76.0;
      if (p.title.isNotEmpty) {
        _txt(p.title, 8, y, size: 2, color: _gold);
        y += 24;
      }
      if (p.org.isNotEmpty) _txt(p.org, 8, y, color: _accent);
    }
    if (p.hasQr) {
      // The real matrix lives on the badge; draw a stand-in with the three finder squares.
      const side = 111.0;
      const x = 320 - side - 8;
      const y = 42.0;
      _c.drawRect(const Rect.fromLTWH(x, y, side, side), Paint()..color = Colors.white);
      for (final (fx, fy) in [(x + 9, y + 9), (x + side - 9 - 21, y + 9), (x + 9, y + side - 9 - 21)]) {
        _c.drawRect(Rect.fromLTWH(fx, fy, 21, 21), Paint()..color = Colors.black);
        _c.drawRect(Rect.fromLTWH(fx + 3, fy + 3, 15, 15), Paint()..color = Colors.white);
        _c.drawRect(Rect.fromLTWH(fx + 6, fy + 6, 9, 9), Paint()..color = Colors.black);
      }
      final rnd = math.Random(7);
      for (var i = 0; i < 90; i++) {
        final mx = x + 9 + rnd.nextInt(31) * 3.0, my = y + 9 + rnd.nextInt(31) * 3.0;
        if ((mx < x + 33 && my < y + 33) || (mx > x + side - 33 && my < y + 33) || (mx < x + 33 && my > y + side - 33)) continue;
        _c.drawRect(Rect.fromLTWH(mx, my, 3, 3), Paint()..color = Colors.black);
      }
    }
    _txt(p.hasQr ? 'hold 4 = big QR   hold 6 = back' : 'hold 6 = back', 8, 160, color: _dim);
  }

  // ------------------------------------------------------------------- inbox
  void _inbox() {
    _title('Inbox', _sky);
    if (st.messages.isEmpty) {
      _txt('No messages - send one from the app', 8, 60, color: _dim);
      _backHint();
      return;
    }
    var y = 46.0;
    for (final m in st.messages.take(5)) {
      _circle(11, y + 4, 2, m.unread ? _sky : _dim);
      _txt(m.text.length > 44 ? '${m.text.substring(0, 42)}..' : m.text, 20, y, color: m.unread ? _text : _dim);
      y += 15;
    }
    _txt('6/4 browse  hold 4: delete', 8, 148, color: _dim);
    _backHint();
  }

  @override
  bool shouldRepaint(covariant _BadgePainter old) => true;
}
