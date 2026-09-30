import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/qr_bitmap.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

enum QrKind { contact, link, text }

/// The badge's Name tag screen: your name, title and organisation in big letters, plus an optional QR code
/// (a contact card, a link, or any text) that people can scan straight off the little screen.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _name = TextEditingController();
  final _title = TextEditingController();
  final _org = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _url = TextEditingController();
  final _text = TextEditingController();
  QrKind _kind = QrKind.contact;
  bool _withQr = false;
  bool _busy = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final p = app.status?.profile;
    _name.text = p?.name ?? '';
    _title.text = p?.title ?? '';
    _org.text = p?.org ?? '';
    final s = app.settings;
    _phone.text = s.stringOf('qrPhone');
    _email.text = s.stringOf('qrEmail');
    _url.text = s.stringOf('qrUrl');
    _text.text = s.stringOf('qrText');
    _kind = QrKind.values.firstWhere((k) => k.name == s.stringOf('qrKind', 'contact'), orElse: () => QrKind.contact);
    _withQr = p?.hasQr ?? false;
    _loaded = p != null;
  }

  @override
  void dispose() {
    for (final c in [_name, _title, _org, _phone, _email, _url, _text]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _payload => switch (_kind) {
    QrKind.contact =>
      _name.text.trim().isEmpty
          ? ''
          : meCard(
              name: _name.text.trim(),
              phone: _phone.text.trim(),
              email: _email.text.trim(),
              url: _url.text.trim(),
              org: _org.text.trim(),
            ),
    QrKind.link => _url.text.trim(),
    QrKind.text => _text.text.trim(),
  };

  ({QrBitmap? bitmap, String? error}) _build() {
    final payload = _payload;
    if (!_withQr || payload.isEmpty) return (bitmap: null, error: null);
    try {
      return (bitmap: buildQrBitmap(payload), error: null);
    } on QrTooLong catch (e) {
      return (bitmap: null, error: e.toString());
    }
  }

  Future<void> _remember() async {
    final s = context.read<AppState>().settings;
    await s.setString('qrPhone', _phone.text);
    await s.setString('qrEmail', _email.text);
    await s.setString('qrUrl', _url.text);
    await s.setString('qrText', _text.text);
    await s.setString('qrKind', _kind.name);
  }

  Future<void> _send() async {
    final app = context.read<AppState>();
    final built = _build();
    if (_withQr && built.bitmap == null) {
      app.toast(built.error ?? 'Fill in what the QR code should contain first.', error: true);
      return;
    }
    setState(() => _busy = true);
    await _remember();
    await app.saveProfile(name: _name.text.trim(), title: _title.text.trim(), org: _org.text.trim(), qr: built.bitmap, removeQr: !_withQr);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final p = app.status?.profile;
    if (!_loaded && p != null) {
      // the first status arrived after this page opened
      _loaded = true;
      _name.text = p.name;
      _title.text = p.title;
      _org.text = p.org;
      _withQr = p.hasQr;
    }
    final built = _build();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Name tag')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          const ConnectionBanner(),
          SectionCard(
            title: 'On the badge',
            accent: Palette.gold,
            child: Column(
              children: [
                TextField(
                  controller: _name,
                  maxLength: 24,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name', counterText: ''),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _title,
                  maxLength: 32,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Title', counterText: ''),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _org,
                  maxLength: 32,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Organisation', counterText: ''),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 6),
                Text(
                  "The badge's font is plain ASCII: accented letters are folded (é becomes e) and emoji are dropped.",
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'QR code',
            accent: Palette.gold,
            trailing: Switch(value: _withQr, onChanged: (v) => setState(() => _withQr = v)),
            child: !_withQr
                ? Text(
                    'Turn it on to show a scannable code next to your name. Hold button 4 on the Name tag screen for a full-screen version.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<QrKind>(
                        segments: const [
                          ButtonSegment(value: QrKind.contact, label: Text('Contact'), icon: Icon(Icons.contact_page)),
                          ButtonSegment(value: QrKind.link, label: Text('Link'), icon: Icon(Icons.link)),
                          ButtonSegment(value: QrKind.text, label: Text('Text'), icon: Icon(Icons.notes)),
                        ],
                        selected: {_kind},
                        onSelectionChanged: (s) => setState(() => _kind = s.first),
                      ),
                      const SizedBox(height: 12),
                      if (_kind == QrKind.contact) ...[
                        TextField(
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Phone (optional)'),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Email (optional)'),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _url,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(labelText: 'Website (optional)'),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Made from the name above as a contact card that phones offer to save when scanned.',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                      if (_kind == QrKind.link)
                        TextField(
                          controller: _url,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(labelText: 'Link', hintText: 'https://...'),
                          onChanged: (_) => setState(() {}),
                        ),
                      if (_kind == QrKind.text)
                        TextField(
                          controller: _text,
                          maxLines: 3,
                          decoration: const InputDecoration(labelText: 'Text'),
                          onChanged: (_) => setState(() {}),
                        ),
                      const SizedBox(height: 14),
                      Center(
                        child: QrPreview(bitmap: built.bitmap, error: built.error),
                      ),
                      if (built.bitmap != null)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '${built.bitmap!.size} x ${built.bitmap!.size} modules - the badge fits up to $badgeMaxQrModules',
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: !app.badgeAnswering || _busy || (_withQr && built.bitmap == null) ? null : _send,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_to_mobile),
            label: const Text('Send to badge'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
        ],
      ),
    );
  }
}

/// Draws the QR the way the badge will: dark modules on a white box with a quiet zone.
class QrPreview extends StatelessWidget {
  const QrPreview({super.key, required this.bitmap, this.error, this.size = 200});
  final QrBitmap? bitmap;
  final String? error;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (bitmap == null) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: error != null ? Palette.coral : Colors.white24),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          error ?? 'Fill in the details to preview the code',
          textAlign: TextAlign.center,
          style: TextStyle(color: error != null ? Palette.coral : Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return CustomPaint(size: Size.square(size), painter: _QrPainter(bitmap!));
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.qr);
  final QrBitmap qr;

  @override
  void paint(Canvas canvas, Size size) {
    const quiet = 2;
    final cell = size.width / (qr.size + 2 * quiet);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)), Paint()..color = Colors.white);
    final dark = Paint()..color = Colors.black;
    for (var r = 0; r < qr.size; r++) {
      for (var c = 0; c < qr.size; c++) {
        if (qr.isDark(r, c)) canvas.drawRect(Rect.fromLTWH((c + quiet) * cell, (r + quiet) * cell, cell + 0.4, cell + 0.4), dark);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter old) => old.qr.hex != qr.hex;
}
