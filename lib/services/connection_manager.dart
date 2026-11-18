import 'dart:async';
import 'dart:convert';

import '../core/bytes.dart';
import '../core/identity.dart';
import '../core/protocol.dart';
import '../data/message_repository.dart';
import '../data/peer_repository.dart';
import '../transport/peer_channel.dart';
import 'pairing_service.dart';
import 'transfer_service.dart';

/// A pending "pair with this device?" decision for the UI.
class PairingRequest {
  PairingRequest({
    required this.peerName,
    required this.peerPlatform,
    required this.sas,
    required this.requiresSasComparison,
    required this.initiatedLocally,
  });

  final String peerName;
  final String peerPlatform;
  final String sas;

  /// True for manual pairing: the user must verify [sas] matches the other
  /// screen. False for QR pairing (trust comes from the scanned key + token).
  final bool requiresSasComparison;
  final bool initiatedLocally;

  final Completer<bool> _decision = Completer<bool>();
  Future<bool> get decision => _decision.future;
  void approve() {
    if (!_decision.isCompleted) _decision.complete(true);
  }

  void reject() {
    if (!_decision.isCompleted) _decision.complete(false);
  }
}

class _Session {
  _Session(this.channel);
  final PeerChannel channel;
  DateTime lastRx = DateTime.now();
}

/// Owns live connections: reconnection, pairing handshake flow, and the
/// message synchronisation protocol on top of [PeerChannel]s. Contains no UI
/// and no socket code.
class ConnectionManager {
  ConnectionManager({
    required this.identity,
    required this.transport,
    required this.peers,
    required this.messages,
    required this.pairing,
    this.reconnectInterval = const Duration(seconds: 6),
    this.keepAliveInterval = const Duration(seconds: 15),
  });

  final DeviceIdentity identity;
  final Transport transport;
  final PeerRepository peers;
  final MessageRepository messages;
  final PairingService pairing;
  final Duration reconnectInterval;
  final Duration keepAliveInterval;

  final _sessions = <String, _Session>{};
  final _connecting = <String>{};
  final _requests = StreamController<PairingRequest>.broadcast();
  final _notices = StreamController<String>.broadcast();
  final _state = StreamController<void>.broadcast();
  StreamSubscription<PeerChannel>? _incomingSub;
  Timer? _timer;
  bool _started = false;

  /// Set by [TransferService]; handles file_* protocol messages.
  TransferService? transfers;

  PeerChannel? channelOf(String deviceId) => _sessions[deviceId]?.channel;

  Future<void> broadcastMessages(List<ChatMessage> msgs) => _broadcast(msgs);

  Stream<PairingRequest> get pairingRequests => _requests.stream;

  /// Human-readable one-off events (paired, rejected, errors).
  Stream<String> get notices => _notices.stream;

  /// Fires when connection state changes.
  Stream<void> get stateChanges => _state.stream;

  Set<String> get onlinePeerIds => _sessions.keys.toSet();
  bool isOnline(String deviceId) => _sessions.containsKey(deviceId);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await transport.start();
    _incomingSub = transport.incoming.listen((ch) => _runSession(ch));
    _timer = Timer.periodic(reconnectInterval, (_) => reconnectNow());
    unawaited(reconnectNow());
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _incomingSub?.cancel();
    for (final s in _sessions.values.toList()) {
      await s.channel.close();
    }
    await transport.stop();
    _started = false;
  }

  // --- connecting ---------------------------------------------------------

  /// Try to reach every paired peer that is not currently connected.
  Future<void> reconnectNow() async {
    for (final p in await peers.all()) {
      _tryConnect(p);
    }
  }

  void _tryConnect(Peer p) {
    if (_sessions.containsKey(p.deviceId) ||
        _connecting.contains(p.deviceId) ||
        p.lastHost == null ||
        p.lastPort == null) {
      return;
    }
    _connecting.add(p.deviceId);
    unawaited(() async {
      try {
        final ch = await transport.connect(
          PeerAddress(p.lastHost!, p.lastPort!),
          expectedPublicKey: p.publicKey,
        );
        unawaited(_runSession(ch));
      } catch (_) {
        // Offline / address changed; retried on the next tick or discovery.
      } finally {
        _connecting.remove(p.deviceId);
      }
    }());
  }

  /// A discovery beacon claims [deviceId] is at [host]:[port]. Purely a hint:
  /// the connection is still authenticated against the pinned key.
  Future<void> onDiscovered(String deviceId, String host, int port) async {
    final p = await peers.get(deviceId);
    if (p == null || _sessions.containsKey(deviceId)) return;
    if (p.lastHost != host || p.lastPort != port) {
      await peers.touch(deviceId, host: host, port: port);
    }
    final fresh = await peers.get(deviceId);
    if (fresh != null) _tryConnect(fresh);
  }

  /// Manual pairing: connect to ip:port. The pairing UI is driven through
  /// [pairingRequests]. Throws if the device cannot be reached.
  Future<void> pairWithAddress(String host, int port) async {
    final ch = await transport.connect(PeerAddress(host.trim(), port));
    unawaited(_runSession(ch));
  }

  /// QR pairing: connect to a scanned code, pinning the advertised key.
  Future<void> pairWithQr(PairingQrPayload qr) async {
    Object? lastError;
    for (final a in qr.addresses) {
      try {
        final ch = await transport.connect(PeerAddress(a, qr.port),
            expectedPublicKey: qr.publicKey, pairingToken: qr.token);
        unawaited(_runSession(ch, autoApprove: true));
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? StateError('No address to connect to');
  }

  Future<void> removePeer(String deviceId) async {
    await _sessions[deviceId]?.channel.close();
    await peers.remove(deviceId);
    _state.add(null);
  }

  // --- sending ------------------------------------------------------------

  /// Stores locally first (durable), then pushes to whoever is online.
  /// Offline peers receive it via sync on their next connection.
  Future<ChatMessage> sendText(String text) async {
    if (text.trim().isEmpty) throw ArgumentError('Empty message');
    if (utf8.encode(text).length > maxTextBytes) {
      throw ArgumentError('Message too large (max 1 MiB of text)');
    }
    final msg = await messages.createLocalText(text, identity.name);
    await _broadcast([msg]);
    return msg;
  }

  Future<void> _broadcast(List<ChatMessage> msgs, {String? exceptDevice}) async {
    for (final e in _sessions.entries.toList()) {
      if (e.key == exceptDevice) continue;
      try {
        await e.value.channel.send({'t': 'msgs', 'msgs': [for (final m in msgs) m.toJson()]});
      } catch (_) {
        // Connection is dying; the message stays safe locally and syncs later.
      }
    }
  }

  // --- session ------------------------------------------------------------

  Future<void> _runSession(PeerChannel ch, {bool autoApprove = false}) async {
    Timer? keepAlive;
    var registered = false;
    try {
      final known = await peers.get(ch.remoteDeviceId);
      final trusted =
          known != null && constantTimeEquals(known.publicKey, ch.remotePublicKey);

      if (!trusted && !ch.initiatedLocally && !pairing.isAccepting) {
        // Unknown device and we are not in pairing mode: say nothing else.
        await ch.send({'t': 'bye', 'reason': 'not_pairing'}).catchError((_) {});
        await ch.close();
        return;
      }
      await ch.send({'t': 'session', 'v': protocolVersion, 'trusted': trusted});
      final first = await ch.receive(timeout: const Duration(seconds: 15));
      if (first == null || first['t'] == 'bye') {
        if (first?['reason'] == 'not_pairing') {
          _notice('${ch.remoteName} is not in pairing mode. Open "Pair device" there first.');
        }
        await ch.close();
        return;
      }
      if (first['t'] != 'session') throw ProtocolException('expected session');
      if ((first['v'] as int? ?? 0) != protocolVersion) {
        _notice('${ch.remoteName} uses an incompatible protocol version.');
        await ch.close();
        return;
      }
      final remoteTrusted = first['trusted'] == true;

      if (trusted != remoteTrusted) {
        _notice(trusted
            ? '${ch.remoteName} no longer recognises this device. Remove it from the list and pair again.'
            : '${ch.remoteName} still trusts a previous pairing. Remove this device there, then pair again.');
        await ch.send({'t': 'bye', 'reason': 'trust_mismatch'}).catchError((_) {});
        await ch.close();
        return;
      }

      if (!trusted) {
        final ok = await _pairingFlow(ch, autoApprove: autoApprove);
        if (!ok) {
          await ch.close();
          return;
        }
      }

      // Ready: enforce a single connection per peer.
      if (!_register(ch)) {
        await ch.close();
        return;
      }
      registered = true;
      unawaited(peers.touch(ch.remoteDeviceId,
          host: ch.remoteHost,
          port: ch.remoteListenPort,
          name: ch.remoteName));
      _state.add(null);

      final session = _sessions[ch.remoteDeviceId]!;
      keepAlive = Timer.periodic(keepAliveInterval, (_) {
        if (DateTime.now().difference(session.lastRx) > keepAliveInterval * 3) {
          ch.close();
        } else {
          ch.send({'t': 'ping'}).catchError((_) {});
        }
      });

      await ch.send({'t': 'sync_hello', 'vector': await messages.vector()});

      while (true) {
        final m = await ch.receive();
        if (m == null) break;
        session.lastRx = DateTime.now();
        await _handle(ch, m);
      }
    } catch (e) {
      // Any protocol violation / IO error ends only this session.
      await ch.close();
    } finally {
      keepAlive?.cancel();
      if (registered && _sessions[ch.remoteDeviceId]?.channel == ch) {
        _sessions.remove(ch.remoteDeviceId);
        _state.add(null);
      }
    }
  }

  /// Both sides prefer the connection initiated by the lexicographically
  /// smaller device id, so simultaneous dials converge on one connection.
  bool _register(PeerChannel ch) {
    final id = ch.remoteDeviceId;
    final existing = _sessions[id];
    if (existing != null && !existing.channel.isClosed) {
      String initiator(PeerChannel c) =>
          c.initiatedLocally ? identity.deviceId : c.remoteDeviceId;
      final cmp = initiator(ch).compareTo(initiator(existing.channel));
      if (cmp > 0) return false; // keep existing
      existing.channel.close();
    }
    _sessions[id] = _Session(ch);
    return true;
  }

  Future<bool> _pairingFlow(PeerChannel ch, {required bool autoApprove}) async {
    if (!ch.initiatedLocally && !pairing.isAccepting) {
      await ch.send({'t': 'bye', 'reason': 'not_pairing'}).catchError((_) {});
      return false;
    }
    final tokenOk = !ch.initiatedLocally && await pairing.verifyProof(ch);
    final req = PairingRequest(
      peerName: ch.remoteName,
      peerPlatform: ch.remotePlatform,
      sas: ch.sas,
      requiresSasComparison: !(tokenOk || autoApprove),
      initiatedLocally: ch.initiatedLocally,
    );
    var accepted = true;
    if (!autoApprove) {
      _requests.add(req);
      // Abort (and dismiss the dialog) if the peer disconnects meanwhile.
      unawaited(ch.closed.then((_) => req.reject()));
      accepted = await req.decision
          .timeout(const Duration(minutes: 2), onTimeout: () => false);
      req.reject(); // no-op if already decided; marks the dialog finished
    }
    await ch.send({'t': 'pair_decision', 'accept': accepted});
    final d = await ch.receive(timeout: const Duration(minutes: 2, seconds: 10));
    if (!accepted || d == null || d['t'] != 'pair_decision' || d['accept'] != true) {
      _notice(accepted
          ? '${ch.remoteName} declined pairing.'
          : 'Pairing with ${ch.remoteName} cancelled.');
      return false;
    }
    if (tokenOk) pairing.consumeToken();
    await peers.upsert(Peer(
      deviceId: ch.remoteDeviceId,
      name: ch.remoteName,
      platform: ch.remotePlatform,
      publicKey: ch.remotePublicKey,
      pairedAt: DateTime.now().millisecondsSinceEpoch,
      lastHost: ch.remoteHost,
      lastPort: ch.remoteListenPort,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
    ));
    _notice('Paired with ${ch.remoteName}.');
    return true;
  }

  Future<void> _handle(PeerChannel ch, Map<String, dynamic> m) async {
    final peerId = ch.remoteDeviceId;
    switch (m['t']) {
      case 'sync_hello':
        final vec = parseVector(m['vector']);
        await peers.mergeVector(peerId, vec);
        await _sendMissing(ch, vec);
      case 'msgs':
        final list = m['msgs'];
        if (list is! List) throw ProtocolException('msgs not a list');
        final parsed = list.map(ChatMessage.fromJson).toList();
        final res = await messages.apply(parsed);
        // Relay to our other peers (multi-device convergence).
        if (res.inserted.isNotEmpty) {
          await _broadcast(res.inserted, exceptDevice: peerId);
        }
        await ch.send({'t': 'vector', 'vector': await messages.vector()});
        if (res.gaps > 0) {
          // We missed something: ask for a full resync.
          await ch.send({'t': 'sync_hello', 'vector': await messages.vector()});
        }
      case 'vector':
        await peers.mergeVector(peerId, parseVector(m['vector']));
      case 'ping':
        break;
      case 'bye':
        await ch.close();
      case 'file_get' || 'file_start' || 'file_chunk' || 'file_end' || 'file_err':
        await transfers?.handle(ch, m);
      default:
        break; // Unknown types are ignored for forward compatibility.
    }
  }

  Future<void> _sendMissing(PeerChannel ch, Map<String, int> peerVector) async {
    final vec = Map<String, int>.from(peerVector);
    while (true) {
      final batch = await messages.missingFor(vec, limit: 50);
      if (batch.isEmpty) break;
      // Keep every frame well below maxFrameBytes.
      var chunk = <ChatMessage>[];
      var size = 0;
      Future<void> flush() async {
        if (chunk.isEmpty) return;
        await ch.send({'t': 'msgs', 'msgs': [for (final m in chunk) m.toJson()]});
        chunk = [];
        size = 0;
      }

      for (final m in batch) {
        final n = m.body.length * 3 + 512; // worst-case UTF-8 estimate
        if (size + n > 3 * 1024 * 1024) await flush();
        chunk.add(m);
        size += n;
        vec[m.originDeviceId] = m.originSeq;
      }
      await flush();
    }
  }

  void _notice(String s) {
    if (!_notices.isClosed) _notices.add(s);
  }
}
