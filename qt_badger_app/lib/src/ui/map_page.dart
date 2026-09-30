import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Where the badge is, where it's pointing, and who's near it. Long-press the map to send the badge somewhere.
class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _map = MapController();
  Timer? _trackTimer;
  bool _centeredOnce = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    app.refreshTrack();
    _trackTimer = Timer.periodic(const Duration(seconds: 10), (_) => app.refreshTrack());
  }

  @override
  void dispose() {
    _trackTimer?.cancel();
    _map.dispose();
    super.dispose();
  }

  LatLng? _badgePos(HubStatus? st) => st != null && st.gps.hasFix ? LatLng(st.gps.lat!, st.gps.lon!) : null;

  LatLng _initialCenter(AppState app) {
    final st = app.status;
    return _badgePos(st) ??
        (app.phone != null ? LatLng(app.phone!.lat, app.phone!.lon) : null) ??
        (st != null ? LatLng(st.destination.lat, st.destination.lon) : const LatLng(6.6887, -1.6243));
  }

  void _moveTo(LatLng p, {double? zoom}) => _map.move(p, zoom ?? math.max(_map.camera.zoom, 16));

  Future<void> _fitAll(AppState app) async {
    final st = app.status;
    final pts = <LatLng>[
      if (_badgePos(st) != null) _badgePos(st)!,
      if (st != null) LatLng(st.destination.lat, st.destination.lon),
      if (app.phone != null) LatLng(app.phone!.lat, app.phone!.lon),
      ...?st?.peers.map((p) => LatLng(p.lat, p.lon)),
    ];
    if (pts.length < 2) {
      if (pts.isNotEmpty) _moveTo(pts.first);
      return;
    }
    _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.fromLTRB(48, 150, 48, 120), maxZoom: 18));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final badge = _badgePos(st);
    final dest = st == null ? null : LatLng(st.destination.lat, st.destination.lon);
    final scheme = Theme.of(context).colorScheme;

    if (!_centeredOnce && (badge != null || app.phone != null)) {
      _centeredOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _moveTo(badge ?? LatLng(app.phone!.lat, app.phone!.lon));
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        actions: [
          IconButton(
            tooltip: 'Set destination by coordinates',
            icon: const Icon(Icons.edit_location_alt_outlined),
            onPressed: st == null ? null : () => _editDestination(context, st.destination),
          ),
          IconButton(tooltip: 'Show everything', icon: const Icon(Icons.fit_screen), onPressed: () => _fitAll(app)),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _initialCenter(app),
              initialZoom: 16,
              minZoom: 3,
              maxZoom: 19,
              onLongPress: (_, p) => _confirmDestination(context, p),
            ),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.qtbadger.qt_badger'),
              if (app.track.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [for (final t in app.track) LatLng(t.lat, t.lon)],
                      strokeWidth: 4,
                      color: Palette.cyan.withValues(alpha: 0.85),
                    ),
                  ],
                ),
              if (badge != null && dest != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [badge, dest],
                      strokeWidth: 2,
                      color: Palette.amber.withValues(alpha: 0.9),
                      pattern: StrokePattern.dashed(segments: const [8, 6]),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (dest != null) _marker(dest, Icons.flag, Palette.amber, label: st!.destination.name),
                  for (final p in st?.peers ?? const <PeerItem>[])
                    _marker(LatLng(p.lat, p.lon), Icons.person_pin_circle, Palette.green, label: p.label),
                  if (app.phone != null)
                    _marker(LatLng(app.phone!.lat, app.phone!.lon), Icons.my_location, const Color(0xFF3B82F6), label: 'You'),
                  if (badge != null) _marker(badge, Icons.badge, Palette.cyan, label: 'Badge'),
                ],
              ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(
                    '(c) OpenStreetMap contributors',
                    onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
                  ),
                ],
              ),
            ],
          ),
          Positioned(top: 8, left: 8, right: 8, child: _InfoCard(st: st)),
          Positioned(
            right: 12,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'locate',
                  tooltip: 'My location',
                  onPressed: () async {
                    final fix = await app.locateOnce();
                    if (fix != null && mounted) _moveTo(LatLng(fix.lat, fix.lon));
                  },
                  child: const Icon(Icons.my_location),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'badge',
                  tooltip: 'Center on the badge',
                  onPressed: badge == null ? null : () => _moveTo(badge),
                  child: const Icon(Icons.badge),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'dest',
                  tooltip: 'Center on the destination',
                  onPressed: dest == null ? null : () => _moveTo(dest),
                  child: const Icon(Icons.flag),
                ),
              ],
            ),
          ),
          Positioned(
            left: 12,
            bottom: 16,
            right: 72,
            child: Card(
              child: SwitchListTile(
                dense: true,
                value: app.settings.assistPosition,
                onChanged: app.badgeAnswering ? (v) => app.setAssistPosition(v) : null,
                title: const Text('Use phone GPS on the badge'),
                subtitle: Text(
                  app.settings.assistPosition
                      ? 'Sending this phone\'s location every few seconds'
                      : 'For indoors, when the badge has no fix',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Marker _marker(LatLng p, IconData icon, Color color, {required String label}) => Marker(
    point: p,
    width: 96,
    height: 62,
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6)],
          ),
          child: Icon(icon, size: 18, color: Colors.black87),
        ),
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(6)),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Future<void> _confirmDestination(BuildContext context, LatLng p) async {
    final app = context.read<AppState>();
    final name = TextEditingController(text: 'Destination');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send the badge here?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}'),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              maxLength: 24,
              decoration: const InputDecoration(labelText: 'Name shown on the badge'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Set destination')),
        ],
      ),
    );
    if (ok == true) await app.setDestination(name.text.trim().isEmpty ? 'Destination' : name.text.trim(), p.latitude, p.longitude);
    name.dispose();
  }

  Future<void> _editDestination(BuildContext context, Destination d) async {
    final app = context.read<AppState>();
    final name = TextEditingController(text: d.name);
    final coords = TextEditingController(text: '${d.lat.toStringAsFixed(6)}, ${d.lon.toStringAsFixed(6)}');
    String? error;
    final ok = await showDialog<LatLng>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Destination'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 24,
                decoration: const InputDecoration(labelText: 'Name shown on the badge'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: coords,
                decoration: InputDecoration(
                  labelText: 'Coordinates or a map link',
                  helperText: 'e.g. 6.6887, -1.6243  or a Google/OpenStreetMap link',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final p = parseCoordinates(coords.text);
                if (p == null) {
                  setLocal(() => error = "Couldn't find coordinates in that");
                } else {
                  Navigator.pop(context, p);
                }
              },
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
    if (ok != null) {
      await app.setDestination(name.text.trim().isEmpty ? 'Destination' : name.text.trim(), ok.latitude, ok.longitude);
      if (mounted) _moveTo(ok);
    }
    name.dispose();
    coords.dispose();
  }
}

/// Pulls a latitude/longitude out of "6.68, -1.62", "@6.68,-1.62,17z" (Google Maps), "?q=6.68,-1.62", "mlat=..&mlon=..".
LatLng? parseCoordinates(String input) {
  final s = input.trim();
  final mlat = RegExp(r'mlat=(-?\d+(?:\.\d+)?).*?mlon=(-?\d+(?:\.\d+)?)').firstMatch(s);
  final m = mlat ?? RegExp(r'(-?\d{1,3}(?:\.\d+)?)\s*[,;\s]\s*(-?\d{1,3}(?:\.\d+)?)').firstMatch(s.replaceFirst('@', ' '));
  if (m == null) return null;
  final lat = double.tryParse(m.group(1)!), lon = double.tryParse(m.group(2)!);
  if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return null;
  return LatLng(lat, lon);
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.st});
  final HubStatus? st;

  @override
  Widget build(BuildContext context) {
    final g = st?.gps;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            if (g != null && g.hasFix && g.bearing != null)
              Transform.rotate(
                angle: g.bearing! * math.pi / 180,
                child: const Icon(Icons.navigation, size: 34, color: Palette.cyan),
              )
            else
              Icon(Icons.gps_off, size: 30, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    st?.destination.name ?? '-',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                  Text(
                    g != null && g.hasFix
                        ? '${fmtDistance(g.distanceM)}  -  bearing ${g.bearing?.round() ?? '-'} deg'
                        : 'Waiting for a position...',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (g != null) Pill(g.hasFix ? g.sourceLabel : '${g.satellites} sats', color: g.hasFix ? Palette.green : Palette.amber),
          ],
        ),
      ),
    );
  }
}
