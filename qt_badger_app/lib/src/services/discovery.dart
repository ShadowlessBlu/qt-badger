// Finds the badge on the local network.
//
// Why a scanner and not a saved IP: the badge usually lives on a phone hotspot
// or a router that hands out addresses, and the subnet can change between
// sessions (192.168.221.x one day, 192.168.157.x the next). So: walk every /24
// this phone is connected to and ask each address for /api/health on the hub's
// port. Cheap (a few seconds) and needs no mDNS or special permissions.
//
// The dart:io implementation lives in discovery_io.dart; web builds (used for
// development only) get a stub that finds nothing.

export 'discovery_stub.dart' if (dart.library.io) 'discovery_io.dart';
