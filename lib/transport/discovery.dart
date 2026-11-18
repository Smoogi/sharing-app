import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// LAN discovery by UDP broadcast beacons (no extra packages, no multicast
/// lock needed on Android). Each running app announces
/// `{smoogi:1, id:<deviceId>, port:<tcpPort>}` every few seconds; a paired
/// device that changed IP is found again from its beacon.
///
/// Beacons are unauthenticated hints only. They reveal the device id (a hash
/// of the public key) to the LAN but grant nothing: the follow-up TCP
/// connection must still prove the pinned identity key.
class DiscoveryService {
  DiscoveryService({
    required this.deviceId,
    required this.portProvider,
    required this.onSeen,
    this.udpPort = 48621,
    this.interval = const Duration(seconds: 5),
    this.targets,
  });

  final String deviceId;
  final int Function() portProvider;
  final void Function(String deviceId, String host, int port) onSeen;
  final int udpPort;
  final Duration interval;

  /// Override broadcast destinations (tests). Defaults to all LAN broadcasts.
  final List<InternetAddress>? targets;

  RawDatagramSocket? _socket;
  Timer? _timer;

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort,
          reuseAddress: true, reusePort: !Platform.isWindows);
    } catch (_) {
      return; // Discovery is best-effort; manual addresses still work.
    }
    _socket!.broadcastEnabled = true;
    _socket!.listen((e) {
      if (e != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = _socket?.receive()) != null) {
        final hit = parseBeacon(d!.data);
        if (hit != null && hit.$1 != deviceId) {
          onSeen(hit.$1, d.address.address, hit.$2);
        }
      }
    });
    await _announce();
    _timer = Timer.periodic(interval, (_) => _announce());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _socket?.close();
    _socket = null;
  }

  Future<void> _announce() async {
    final s = _socket;
    if (s == null) return;
    final data = encodeBeacon(deviceId, portProvider());
    final dests = targets ?? await _broadcastTargets();
    for (final a in dests) {
      try {
        s.send(data, a, udpPort);
      } catch (_) {}
    }
  }

  static Future<List<InternetAddress>> _broadcastTargets() async {
    final out = <InternetAddress>[InternetAddress('255.255.255.255')];
    try {
      for (final i in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in i.addresses) {
          final o = a.rawAddress;
          if (o.length == 4) {
            out.add(InternetAddress('${o[0]}.${o[1]}.${o[2]}.255')); // assumes /24
          }
        }
      }
    } catch (_) {}
    return out;
  }

  static List<int> encodeBeacon(String deviceId, int port) =>
      utf8.encode(jsonEncode({'smoogi': 1, 'id': deviceId, 'port': port}));

  /// Returns (deviceId, port) or null for anything that is not a valid beacon.
  static (String, int)? parseBeacon(List<int> data) {
    try {
      if (data.length > 512) return null;
      final j = jsonDecode(utf8.decode(data));
      if (j is Map &&
          j['smoogi'] == 1 &&
          j['id'] is String &&
          RegExp(r'^[0-9a-f]{32}$').hasMatch(j['id'] as String) &&
          j['port'] is int &&
          (j['port'] as int) > 0 &&
          (j['port'] as int) < 65536) {
        return (j['id'] as String, j['port'] as int);
      }
    } catch (_) {}
    return null;
  }
}
