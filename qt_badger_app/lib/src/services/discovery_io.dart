import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

bool get canScanNetwork => true;

bool _isPrivate(List<int> o) => o[0] == 10 || (o[0] == 172 && o[1] >= 16 && o[1] <= 31) || (o[0] == 192 && o[1] == 168);

/// Returns the IPs that answered like the QT BADGEr hub. [onProgress] reports (done, total) probes.
Future<List<String>> scanForHubs({int port = 7000, void Function(int done, int total)? onProgress}) async {
  final prefixes = <String>{};
  final own = <String>{};
  try {
    final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    for (final i in ifaces) {
      // Only local networks: a phone's cellular (rmnet*/ccmni*), VPN (tun*) and tunnel interfaces are
      // carrier or remote address space - nothing there is a badge, and probing it would be rude.
      if (RegExp(r'^(rmnet|ccmni|v4-|tun|ppp|dummy|lo|clat|ipsec|tailscale)', caseSensitive: false).hasMatch(i.name)) continue;
      for (final a in i.addresses) {
        final o = a.address.split('.').map(int.parse).toList();
        if (o.length == 4 && _isPrivate(o)) {
          prefixes.add('${o[0]}.${o[1]}.${o[2]}');
          own.add(a.address);
        }
      }
    }
  } catch (_) {
    return const [];
  }

  final targets = <String>[
    for (final p in prefixes)
      for (var h = 1; h <= 254; h++) '$p.$h',
  ]..removeWhere(own.contains);

  final found = <String>[];
  var next = 0, done = 0;
  final client = http.Client();

  Future<void> worker() async {
    while (true) {
      if (next >= targets.length) return;
      final ip = targets[next++];
      try {
        final res = await client
            .get(Uri(scheme: 'http', host: ip, port: port, path: '/api/health'))
            .timeout(const Duration(milliseconds: 900));
        if (res.statusCode == 200) {
          final j = jsonDecode(utf8.decode(res.bodyBytes));
          if (j is Map && j['app'] == 'QT BADGEr') found.add(ip);
        }
      } catch (_) {
        // closed, filtered or not the hub - all the same to us
      }
      onProgress?.call(++done, targets.length);
    }
  }

  await Future.wait(List.generate(48, (_) => worker()));
  client.close();
  found.sort();
  return found;
}
