import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String b64(List<int> bytes) => base64Url.encode(bytes);

Uint8List unb64(String s) => Uint8List.fromList(base64Url.decode(s));

/// Constant-time comparison for secrets / MACs.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List concat(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.toBytes();
}

Future<Uint8List> sha256(List<int> data) async =>
    Uint8List.fromList((await Sha256().hash(data)).bytes);

/// Proof that a connecting device knows the one-time QR pairing token.
/// HMAC-SHA256(token, transcript) — bound to this very handshake, so it
/// cannot be replayed on another connection.
Future<Uint8List> pairingProof(List<int> token, List<int> transcript) async {
  final mac = await Hmac.sha256().calculateMac(
    transcript,
    secretKey: SecretKey(token),
    nonce: utf8.encode('smoogi/v1/pair-proof'),
  );
  return Uint8List.fromList(mac.bytes);
}
