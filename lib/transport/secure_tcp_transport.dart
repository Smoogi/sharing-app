import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/bytes.dart';
import '../core/identity.dart';
import '../core/protocol.dart';
import 'peer_channel.dart';

/// TCP transport with an authenticated key exchange built only from
/// standard primitives (no custom crypto):
///
///  1. Commit/reveal of X25519 ephemeral keys (initiator commits to
///     SHA-256(ephPub) first). This stops an attacker from grinding keys to
///     force equal SAS codes on both legs of a MITM.
///  2. Session keys = HKDF-SHA256(X25519 shared secret, salt = transcript),
///     one key per direction.
///  3. All further traffic is ChaCha20-Poly1305 with per-direction counter
///     nonces (replay / reorder / truncation of frames fails the tag check).
///  4. Each side sends its Ed25519 identity key and a signature over
///     (label || role || transcript) — the STS / SIGMA pattern — so the
///     identity is bound to *this* key exchange.
///  5. Trust is decided above this layer: known key (pinned) or SAS / QR.
///
/// This composition has NOT been independently audited. See README.
class SecureTcpTransport implements Transport {
  SecureTcpTransport({
    required this.identity,
    this.preferredPort = 48620,
    this.platform = 'unknown',
  });

  final DeviceIdentity identity;
  final int preferredPort;
  final String platform;

  ServerSocket? _server;
  final _incoming = StreamController<PeerChannel>.broadcast();

  @override
  int get port => _server?.port ?? 0;

  @override
  Stream<PeerChannel> get incoming => _incoming.stream;

  @override
  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, preferredPort,
          shared: false);
    } on SocketException {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(_onSocket, onError: (_) {});
  }

  @override
  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  Future<void> _onSocket(Socket socket) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    try {
      final ch = await _handshake(socket, initiator: false)
          .timeout(const Duration(seconds: 10));
      if (!_incoming.isClosed) _incoming.add(ch);
    } catch (_) {
      socket.destroy();
    }
  }

  @override
  Future<PeerChannel> connect(
    PeerAddress address, {
    Uint8List? expectedPublicKey,
    Uint8List? pairingToken,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket =
        await Socket.connect(address.host, address.port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    try {
      return await _handshake(socket,
              initiator: true,
              expectedPublicKey: expectedPublicKey,
              pairingToken: pairingToken)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  // --- handshake -----------------------------------------------------------

  static const _magic = [0x53, 0x4d, 0x47, 0x31]; // "SMG1"
  static const _kCommit = 1, _kEph = 2, _kReveal = 3;

  Uint8List _hs(int kind, List<int> payload) =>
      concat([_magic, [kind], payload]);

  Future<Uint8List> _expect(_FrameIO io, int kind) async {
    final f = await io.next();
    if (f == null) throw HandshakeException('connection closed');
    if (f.length != 5 + 32 ||
        f[0] != _magic[0] ||
        f[1] != _magic[1] ||
        f[2] != _magic[2] ||
        f[3] != _magic[3] ||
        f[4] != kind) {
      throw HandshakeException('unexpected handshake frame');
    }
    return Uint8List.sublistView(f, 5);
  }

  Future<_TcpPeerChannel> _handshake(
    Socket socket, {
    required bool initiator,
    Uint8List? expectedPublicKey,
    Uint8List? pairingToken,
  }) async {
    final io = _FrameIO(socket);
    final x25519 = X25519();
    final eph = await x25519.newKeyPair();
    final ephPub = Uint8List.fromList((await eph.extractPublicKey()).bytes);

    late final Uint8List initPub, respPub;
    if (initiator) {
      io.write(_hs(_kCommit, await sha256(ephPub)));
      respPub = Uint8List.fromList(await _expect(io, _kEph));
      io.write(_hs(_kReveal, ephPub));
      initPub = ephPub;
    } else {
      final commit = Uint8List.fromList(await _expect(io, _kCommit));
      io.write(_hs(_kEph, ephPub));
      initPub = Uint8List.fromList(await _expect(io, _kReveal));
      if (!constantTimeEquals(await sha256(initPub), commit)) {
        throw HandshakeException('commitment mismatch');
      }
      respPub = ephPub;
    }

    final transcript =
        await sha256(concat([utf8.encode('smoogi/v1/transcript'), initPub, respPub]));
    final remoteEph = initiator ? respPub : initPub;
    final shared = await x25519.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(remoteEph, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    if (sharedBytes.every((b) => b == 0)) {
      throw HandshakeException('degenerate key exchange');
    }
    final okm = await (await Hkdf(hmac: Hmac.sha256(), outputLength: 64)
            .deriveKey(
                secretKey: shared,
                nonce: transcript,
                info: utf8.encode('smoogi/v1/session-keys')))
        .extractBytes();
    final i2r = SecretKey(okm.sublist(0, 32));
    final r2i = SecretKey(okm.sublist(32, 64));

    final channel = _TcpPeerChannel(
      io: io,
      socket: socket,
      sendKey: initiator ? i2r : r2i,
      recvKey: initiator ? r2i : i2r,
      transcript: transcript,
      initiatedLocally: initiator,
      localDeviceId: identity.deviceId,
      remoteHost: socket.remoteAddress.address,
    );

    // Identity authentication, inside the encrypted channel.
    final myRole = initiator ? 0 : 1;
    final sig = await identity.sign(_authData(myRole, transcript));
    await channel.send({
      't': 'auth',
      'pk': b64(identity.publicKey),
      'sig': b64(sig),
      'name': identity.name,
      'platform': platform,
      'port': port,
      if (pairingToken != null)
        'proof': b64(await pairingProof(pairingToken, transcript)),
    });

    final m = await channel.receive(timeout: const Duration(seconds: 8));
    if (m == null || m['t'] != 'auth') {
      throw HandshakeException('authentication failed');
    }
    final pk = unb64(m['pk'] as String);
    final rsig = unb64(m['sig'] as String);
    if (pk.length != 32) throw HandshakeException('bad identity key');
    final ok = await DeviceIdentity.verify(
        pk, _authData(1 - myRole, transcript), rsig);
    if (!ok) throw HandshakeException('bad identity signature');
    if (expectedPublicKey != null &&
        !constantTimeEquals(pk, expectedPublicKey)) {
      throw HandshakeException('peer identity does not match the paired device');
    }
    final remoteId = await DeviceIdentity.deviceIdFor(pk);
    if (remoteId == identity.deviceId) {
      throw HandshakeException('refusing to connect to self');
    }
    final proof = m['proof'];
    channel._setRemote(
      deviceId: remoteId,
      publicKey: pk,
      name: _clip(m['name'], 64, 'Unknown device'),
      platform: _clip(m['platform'], 32, 'unknown'),
      listenPort: m['port'] is int && (m['port'] as int) > 0 ? m['port'] as int : null,
      proof: proof is String ? unb64(proof) : null,
    );
    return channel;
  }

  static String _clip(Object? v, int max, String fallback) {
    if (v is! String || v.trim().isEmpty) return fallback;
    return v.length > max ? v.substring(0, max) : v;
  }

  static List<int> _authData(int role, Uint8List transcript) =>
      concat([utf8.encode('smoogi/v1/auth'), [role], transcript]);
}

// --- framing -----------------------------------------------------------------

/// Length-prefixed frame reader/writer over a socket.
class _FrameIO {
  _FrameIO(this.socket) {
    socket.listen(_onData,
        onError: (_) => _finish(), onDone: _finish, cancelOnError: true);
  }

  final Socket socket;
  Uint8List _acc = Uint8List(0);
  final _frames = Queue<Uint8List>();
  final _waiters = Queue<Completer<Uint8List?>>();
  bool _done = false;
  final _closedC = Completer<void>();

  bool get isClosed => _done;
  Future<void> get closed => _closedC.future;

  void _onData(Uint8List data) {
    _acc = _acc.isEmpty
        ? data
        : (Uint8List(_acc.length + data.length)
          ..setAll(0, _acc)
          ..setAll(_acc.length, data));
    var off = 0;
    while (_acc.length - off >= 4) {
      final len = ByteData.sublistView(_acc, off, off + 4).getUint32(0);
      if (len > maxFrameBytes) {
        socket.destroy();
        _finish();
        return;
      }
      if (_acc.length - off - 4 < len) break;
      _push(Uint8List.sublistView(_acc, off + 4, off + 4 + len));
      off += 4 + len;
    }
    if (off > 0) _acc = Uint8List.sublistView(_acc, off);
  }

  void _push(Uint8List f) {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(f);
    } else {
      _frames.add(f);
    }
  }

  void _finish() {
    if (_done) return;
    _done = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(null);
    }
    if (!_closedC.isCompleted) _closedC.complete();
  }

  Future<Uint8List?> next({Duration? timeout}) {
    if (_frames.isNotEmpty) return Future.value(_frames.removeFirst());
    if (_done) return Future.value(null);
    final c = Completer<Uint8List?>();
    _waiters.add(c);
    if (timeout == null) return c.future;
    return c.future.timeout(timeout, onTimeout: () {
      _waiters.remove(c);
      throw TimeoutException('receive timed out', timeout);
    });
  }

  void write(Uint8List payload) {
    final header = ByteData(4)..setUint32(0, payload.length);
    socket.add(header.buffer.asUint8List());
    socket.add(payload);
  }

  Future<void> flush() => socket.flush();

  Future<void> close() async {
    _finish();
    socket.destroy();
  }
}

// --- encrypted channel ---------------------------------------------------------

class _TcpPeerChannel implements PeerChannel {
  _TcpPeerChannel({
    required _FrameIO io,
    required Socket socket,
    required SecretKey sendKey,
    required SecretKey recvKey,
    required this.transcript,
    required this.initiatedLocally,
    required this.localDeviceId,
    required this.remoteHost,
  })  : _io = io,
        _sendKey = sendKey,
        _recvKey = recvKey;

  final _FrameIO _io;
  final SecretKey _sendKey;
  final SecretKey _recvKey;
  final _aead = Chacha20.poly1305Aead();
  int _sendCounter = 0;
  int _recvCounter = 0;
  Future<void> _sendChain = Future.value();

  @override
  final Uint8List transcript;
  @override
  final bool initiatedLocally;
  @override
  final String localDeviceId;
  @override
  final String remoteHost;

  late String _remoteDeviceId;
  late Uint8List _remotePublicKey;
  late String _remoteName;
  late String _remotePlatform;
  int? _remoteListenPort;
  Uint8List? _pairProof;

  void _setRemote({
    required String deviceId,
    required Uint8List publicKey,
    required String name,
    required String platform,
    required int? listenPort,
    required Uint8List? proof,
  }) {
    _remoteDeviceId = deviceId;
    _remotePublicKey = publicKey;
    _remoteName = name;
    _remotePlatform = platform;
    _remoteListenPort = listenPort;
    _pairProof = proof;
  }

  @override
  String get remoteDeviceId => _remoteDeviceId;
  @override
  Uint8List get remotePublicKey => _remotePublicKey;
  @override
  String get remoteName => _remoteName;
  @override
  String get remotePlatform => _remotePlatform;
  @override
  int? get remoteListenPort => _remoteListenPort;
  @override
  Uint8List? get pairProof => _pairProof;

  @override
  String get sas {
    // Derived synchronously-safe: computed lazily from the transcript bytes.
    // First 4 bytes of the transcript hash (already SHA-256 output) mod 1e6.
    final v = ByteData.sublistView(transcript, 0, 4).getUint32(0) % 1000000;
    final s = v.toString().padLeft(6, '0');
    return '${s.substring(0, 3)} ${s.substring(3)}';
  }

  @override
  bool get isClosed => _io.isClosed;
  @override
  Future<void> get closed => _io.closed;

  Uint8List _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, counter, Endian.little);
    return n;
  }

  @override
  Future<void> send(Map<String, dynamic> message) {
    // Serialise sends: nonce order must equal wire order.
    final result = _sendChain.then((_) async {
      if (_io.isClosed) throw const SocketException('channel closed');
      // Plaintext = [type][body]. type 0: JSON. type 1: raw bytes carried in
      // message['bin'] (file chunks): [1][u32 headerLen][header JSON][bytes].
      final Uint8List plain;
      final bin = message['bin'];
      if (bin is Uint8List) {
        final header =
            utf8.encode(jsonEncode(Map.of(message)..remove('bin')));
        final len = ByteData(4)..setUint32(0, header.length);
        plain = concat([
          [1],
          len.buffer.asUint8List(),
          header,
          bin
        ]);
      } else {
        plain = concat([
          [0],
          utf8.encode(jsonEncode(message))
        ]);
      }
      if (plain.length + 64 > maxFrameBytes) {
        throw ProtocolException('message too large');
      }
      final box = await _aead.encrypt(plain,
          secretKey: _sendKey, nonce: _nonce(_sendCounter++));
      _io.write(Uint8List.fromList([...box.cipherText, ...box.mac.bytes]));
      await _io.flush();
    });
    _sendChain = result.catchError((_) {});
    return result;
  }

  @override
  Future<Map<String, dynamic>?> receive({Duration? timeout}) async {
    final frame = await _io.next(timeout: timeout);
    if (frame == null) return null;
    if (frame.length < 16) {
      await close();
      return null;
    }
    try {
      final ct = frame.sublist(0, frame.length - 16);
      final mac = Mac(frame.sublist(frame.length - 16));
      final plain = await _aead.decrypt(
        SecretBox(ct, nonce: _nonce(_recvCounter), mac: mac),
        secretKey: _recvKey,
      );
      _recvCounter++;
      if (plain.isEmpty) throw const FormatException();
      final bytes = Uint8List.fromList(plain);
      if (bytes[0] == 0) {
        final obj = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 1)));
        if (obj is! Map<String, dynamic>) throw const FormatException();
        return obj;
      }
      if (bytes[0] != 1 || bytes.length < 5) throw const FormatException();
      final hl = ByteData.sublistView(bytes, 1, 5).getUint32(0);
      if (5 + hl > bytes.length) throw const FormatException();
      final obj = jsonDecode(utf8.decode(bytes.sublist(5, 5 + hl)));
      if (obj is! Map<String, dynamic>) throw const FormatException();
      obj['bin'] = bytes.sublist(5 + hl);
      return obj;
    } catch (_) {
      // Tampered, replayed, reordered or malformed frame: kill the channel.
      await close();
      return null;
    }
  }

  @override
  Future<void> close() => _io.close();
}
