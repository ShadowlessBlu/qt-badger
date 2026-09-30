/// Web builds can't open sockets to arbitrary hosts, so there's nothing to scan.
bool get canScanNetwork => false;

Future<List<String>> scanForHubs({int port = 7000, void Function(int done, int total)? onProgress}) async => const [];
