import 'dart:typed_data';

/// Where to reach a peer on the LAN.
class PeerAddress {
  const PeerAddress(this.host, this.port);
  final String host;
  final int port;
  @override
  String toString() => '$host:$port';
}

class HandshakeException implements Exception {
  HandshakeException(this.message);
  final String message;
  @override
  String toString() => 'HandshakeException: $message';
}

/// An authenticated, encrypted, ordered message pipe to one remote device.
///
/// "Authenticated" means the remote proved possession of the private key for
/// [remotePublicKey]; whether that key is *trusted* is decided by the
/// pairing layer, never by the transport.
///
/// The sync engine and UI only know this interface, so a future internet
/// relay transport can be added by implementing [Transport] + [PeerChannel].
abstract class PeerChannel {
  String get localDeviceId;
  String get remoteDeviceId;
  Uint8List get remotePublicKey;
  String get remoteName;
  String get remotePlatform;

  /// Port the remote's listener is bound to (for reconnecting), if any.
  int? get remoteListenPort;

  /// Network address the remote was reached at / connected from.
  String get remoteHost;
  bool get initiatedLocally;

  /// Handshake transcript hash (binds both ephemeral keys).
  Uint8List get transcript;

  /// 6-digit short authentication string derived from [transcript]. Both
  /// users compare it to defeat man-in-the-middle during manual pairing.
  String get sas;

  /// HMAC proof of the one-time QR token supplied by the connecting side.
  Uint8List? get pairProof;

  bool get isClosed;
  Future<void> get closed;

  Future<void> send(Map<String, dynamic> message);

  /// Next message, or null once the channel is closed. Throws
  /// [TimeoutException] if [timeout] elapses first.
  Future<Map<String, dynamic>?> receive({Duration? timeout});

  Future<void> close();
}

abstract class Transport {
  /// Port the local listener is bound to (valid after [start]).
  int get port;
  Stream<PeerChannel> get incoming;
  Future<void> start();
  Future<void> stop();

  /// Connect to a peer. If [expectedPublicKey] is given the connection is
  /// refused unless the peer proves that exact identity. [pairingToken] is
  /// the one-time secret from a scanned QR code.
  Future<PeerChannel> connect(
    PeerAddress address, {
    Uint8List? expectedPublicKey,
    Uint8List? pairingToken,
    Duration timeout = const Duration(seconds: 5),
  });
}
