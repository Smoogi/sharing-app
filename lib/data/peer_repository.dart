import 'dart:async';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

class Peer {
  const Peer({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.publicKey,
    required this.pairedAt,
    this.lastHost,
    this.lastPort,
    this.lastSeen,
  });

  final String deviceId;
  final String name;
  final String platform;
  final Uint8List publicKey;
  final int pairedAt;
  final String? lastHost;
  final int? lastPort;
  final int? lastSeen;
}

class PeerRepository {
  PeerRepository(this._db);
  final Database _db;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  Peer _fromRow(Map<String, Object?> r) => Peer(
        deviceId: r['device_id'] as String,
        name: r['name'] as String,
        platform: r['platform'] as String,
        publicKey: Uint8List.fromList(r['public_key'] as List<int>),
        pairedAt: r['paired_at'] as int,
        lastHost: r['last_host'] as String?,
        lastPort: r['last_port'] as int?,
        lastSeen: r['last_seen'] as int?,
      );

  Future<List<Peer>> all() async => (await _db.query('peers', orderBy: 'paired_at'))
      .map(_fromRow)
      .toList();

  Future<Peer?> get(String deviceId) async {
    final r = await _db.query('peers', where: 'device_id=?', whereArgs: [deviceId]);
    return r.isEmpty ? null : _fromRow(r.first);
  }

  Future<void> upsert(Peer p) async {
    await _db.insert(
        'peers',
        {
          'device_id': p.deviceId,
          'name': p.name,
          'platform': p.platform,
          'public_key': p.publicKey,
          'paired_at': p.pairedAt,
          'last_host': p.lastHost,
          'last_port': p.lastPort,
          'last_seen': p.lastSeen,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    _changes.add(null);
  }

  /// Remember where a peer was last reachable (addresses change over time).
  Future<void> touch(String deviceId, {String? host, int? port, String? name}) async {
    await _db.update(
        'peers',
        {
          if (host != null) 'last_host': host,
          if (port != null) 'last_port': port,
          if (name != null) 'name': name,
          'last_seen': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'device_id=?',
        whereArgs: [deviceId]);
    _changes.add(null);
  }

  Future<void> remove(String deviceId) async {
    await _db.transaction((t) async {
      await t.delete('peers', where: 'device_id=?', whereArgs: [deviceId]);
      await t.delete('peer_vectors', where: 'peer_id=?', whereArgs: [deviceId]);
    });
    _changes.add(null);
  }

  /// Records what [peerId] confirmed it holds. Only ever moves forward.
  Future<void> mergeVector(String peerId, Map<String, int> vector) async {
    await _db.transaction((t) async {
      for (final e in vector.entries) {
        await t.rawInsert(
            'INSERT INTO peer_vectors(peer_id, origin_device, max_seq) VALUES(?,?,?) '
            'ON CONFLICT(peer_id, origin_device) DO UPDATE SET max_seq=MAX(max_seq, excluded.max_seq)',
            [peerId, e.key, e.value]);
      }
    });
    _changes.add(null);
  }

  /// {peerId: {origin: maxSeq}}
  Future<Map<String, Map<String, int>>> vectors() async {
    final rows = await _db.query('peer_vectors');
    final out = <String, Map<String, int>>{};
    for (final r in rows) {
      (out[r['peer_id'] as String] ??= {})[r['origin_device'] as String] =
          r['max_seq'] as int;
    }
    return out;
  }
}
