import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/bytes.dart';
import '../core/identity.dart';
import '../transport/peer_channel.dart';

/// Contents of the pairing QR code.
///
/// The QR carries the displaying device's identity public key (so the scanner
/// can pin it — this is what defeats a MITM), its addresses, and a one-time
/// secret token the scanner must prove knowledge of during the handshake.
class PairingQrPayload {
  PairingQrPayload({
    required this.deviceId,
    required this.publicKey,
    required this.name,
    required this.addresses,
    required this.port,
    required this.token,
  });

  final String deviceId;
  final Uint8List publicKey;
  final String name;
  final List<String> addresses;
  final int port;
  final Uint8List token;

  String encode() => jsonEncode({
        'smoogi': 1,
        'pk': b64(publicKey),
        'n': name,
        'a': addresses,
        'p': port,
        't': b64(token),
      });

  static Future<PairingQrPayload> decode(String text) async {
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      if (j['smoogi'] != 1) throw const FormatException('version');
      final pk = unb64(j['pk'] as String);
      final tok = unb64(j['t'] as String);
      if (pk.length != 32 || tok.length < 16) throw const FormatException('keys');
      final addrs = (j['a'] as List).cast<String>();
      final port = j['p'] as int;
      if (addrs.isEmpty || port <= 0 || port > 65535) {
        throw const FormatException('addr');
      }
      return PairingQrPayload(
        deviceId: await DeviceIdentity.deviceIdFor(pk),
        publicKey: pk,
        name: (j['n'] as String?) ?? 'Device',
        addresses: addrs,
        port: port,
        token: tok,
      );
    } catch (_) {
      throw const FormatException('Not a valid pairing code');
    }
  }
}

/// Holds the "I am currently accepting new devices" state.
class PairingService {
  PairingService({Random? random}) : _random = random ?? Random.secure();
  final Random _random;

  bool _accepting = false;
  Uint8List? _token;
  DateTime? _tokenExpiry;

  bool get isAccepting => _accepting;

  /// Called while the "Pair device" screen is visible. Unknown devices are
  /// refused outright when this is off.
  void setAccepting(bool value) {
    _accepting = value;
    if (!value) _token = null;
  }

  /// Fresh one-time token for a QR code (valid 5 minutes, single use).
  Uint8List newToken() {
    _token = Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256)));
    _tokenExpiry = DateTime.now().add(const Duration(minutes: 5));
    return _token!;
  }

  void consumeToken() {
    _token = null;
  }

  /// True if the remote proved knowledge of the currently active QR token.
  Future<bool> verifyProof(PeerChannel channel) async {
    final t = _token;
    final proof = channel.pairProof;
    if (t == null || proof == null) return false;
    if (_tokenExpiry != null && DateTime.now().isAfter(_tokenExpiry!)) {
      _token = null;
      return false;
    }
    return constantTimeEquals(
        await pairingProof(t, channel.transcript), proof);
  }
}
