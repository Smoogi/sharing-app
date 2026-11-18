import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/protocol.dart';

class ApplyResult {
  ApplyResult(
      {required this.inserted,
      this.duplicates = 0,
      this.gaps = 0,
      this.conflicts = 0});
  final List<ChatMessage> inserted;
  final int duplicates;

  /// Messages skipped because an earlier sequence number is missing.
  final int gaps;

  /// Same (origin, seq) but different content/id — never overwritten.
  final int conflicts;
}

/// Append-only message store. Local sends are durable the moment
/// [createLocalText] returns; delivery is derived from per-peer vectors, so
/// "the outbox" survives restarts by construction.
class MessageRepository {
  MessageRepository(this._db, {required this.localDeviceId});

  final Database _db;
  final String localDeviceId;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  static const _uuid = Uuid();

  Future<ChatMessage> createLocalText(String body, String originName,
      {String kind = 'text', DateTime? now}) async {
    return _db.transaction((txn) async {
      final r = await txn.rawQuery(
          'SELECT COALESCE(MAX(origin_seq),0) AS m FROM messages WHERE origin_device=?',
          [localDeviceId]);
      final seq = (r.first['m'] as int) + 1;
      final msg = ChatMessage(
        id: _uuid.v4(),
        originDeviceId: localDeviceId,
        originName: originName,
        originSeq: seq,
        createdAt: (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
        kind: kind,
        body: body,
      );
      await txn.insert('messages', _row(msg));
      return msg;
    }).then((m) {
      _changes.add(null);
      return m;
    });
  }

  Map<String, Object?> _row(ChatMessage m) => {
        'id': m.id,
        'origin_device': m.originDeviceId,
        'origin_name': m.originName,
        'origin_seq': m.originSeq,
        'created_at': m.createdAt,
        'kind': m.kind,
        'body': m.body,
      };

  ChatMessage _fromRow(Map<String, Object?> r) => ChatMessage(
        id: r['id'] as String,
        originDeviceId: r['origin_device'] as String,
        originName: r['origin_name'] as String,
        originSeq: r['origin_seq'] as int,
        createdAt: r['created_at'] as int,
        kind: r['kind'] as String,
        body: r['body'] as String,
      );

  /// {originDevice: highest contiguous seq held}.
  Future<Map<String, int>> vector() async {
    final rows = await _db.rawQuery(
        'SELECT origin_device, MAX(origin_seq) AS m FROM messages GROUP BY origin_device');
    return {for (final r in rows) r['origin_device'] as String: r['m'] as int};
  }

  /// Messages the peer lacks, ascending per origin, at most [limit].
  Future<List<ChatMessage>> missingFor(Map<String, int> peerVector,
      {int limit = 100}) async {
    final mine = await vector();
    final out = <ChatMessage>[];
    for (final e in mine.entries) {
      if (out.length >= limit) break;
      final have = peerVector[e.key] ?? 0;
      if (e.value <= have) continue;
      final rows = await _db.query('messages',
          where: 'origin_device=? AND origin_seq>?',
          whereArgs: [e.key, have],
          orderBy: 'origin_seq ASC',
          limit: limit - out.length);
      out.addAll(rows.map(_fromRow));
    }
    return out;
  }

  /// Idempotently applies messages received from a peer. A message is only
  /// accepted if it is the next sequence number for its origin, which keeps
  /// every origin's history gap-free.
  Future<ApplyResult> apply(List<ChatMessage> msgs) async {
    final inserted = <ChatMessage>[];
    var dup = 0, gaps = 0, conflicts = 0;
    await _db.transaction((txn) async {
      final maxSeq = <String, int>{};
      for (final m in msgs) {
        final cur = maxSeq[m.originDeviceId] ??= (await txn.rawQuery(
                'SELECT COALESCE(MAX(origin_seq),0) AS m FROM messages WHERE origin_device=?',
                [m.originDeviceId]))
            .first['m'] as int;
        if (m.originSeq <= cur) {
          final ex = await txn.query('messages',
              where: 'origin_device=? AND origin_seq=?',
              whereArgs: [m.originDeviceId, m.originSeq]);
          if (ex.isNotEmpty && _fromRow(ex.first).id == m.id) {
            dup++;
          } else {
            conflicts++;
          }
        } else if (m.originSeq == cur + 1) {
          // id uniqueness is also enforced by the primary key.
          final n = await txn.insert('messages', _row(m),
              conflictAlgorithm: ConflictAlgorithm.ignore);
          if (n > 0) {
            inserted.add(m);
            maxSeq[m.originDeviceId] = m.originSeq;
          } else {
            conflicts++;
          }
        } else {
          gaps++;
        }
      }
    });
    if (inserted.isNotEmpty) _changes.add(null);
    return ApplyResult(
        inserted: inserted, duplicates: dup, gaps: gaps, conflicts: conflicts);
  }

  /// Latest edit per target message id: {id: (text, editTime)}.
  Future<Map<String, (String, int)>> _edits() async {
    final rows = await _db.query('messages',
        where: 'kind=?',
        whereArgs: [editKind],
        orderBy: 'created_at ASC, origin_device ASC, origin_seq ASC');
    final out = <String, (String, int)>{};
    for (final r in rows) {
      try {
        final j = jsonDecode(r['body'] as String);
        if (j is Map && j['t'] is String && j['b'] is String) {
          out[j['t'] as String] = (j['b'] as String, r['created_at'] as int);
        }
      } catch (_) {}
    }
    return out; // later rows overwrite earlier ones => latest wins
  }

  /// Chronological (oldest first), edits applied and edit events hidden.
  /// [query] filters case-insensitively on the *current* text.
  Future<List<ChatMessage>> recent({String? query, int limit = 500}) async {
    final edits = await _edits();
    final q = query?.trim().toLowerCase() ?? '';
    final rows = await _db.query('messages',
        where: 'kind<>?',
        whereArgs: [editKind],
        orderBy: 'created_at DESC, origin_device DESC, origin_seq DESC',
        limit: q.isEmpty ? limit : null);
    final out = <ChatMessage>[];
    for (final r in rows) {
      var m = _fromRow(r);
      final e = m.kind == 'text' ? edits[m.id] : null;
      if (e != null) m = m.withEdit(e.$1, e.$2);
      if (q.isNotEmpty &&
          !m.body.toLowerCase().contains(q) &&
          !m.originName.toLowerCase().contains(q)) {
        continue;
      }
      out.add(m);
      if (out.length >= limit) break;
    }
    return out.reversed.toList();
  }

  /// Appends an edit of text message [target]. Throws if it is not an
  /// editable text message.
  Future<ChatMessage> createEdit(
      String targetId, String newText, String originName) async {
    final rows = await _db.query('messages',
        columns: ['kind'], where: 'id=?', whereArgs: [targetId]);
    if (rows.isEmpty || rows.first['kind'] != 'text') {
      throw ArgumentError('Only text messages can be edited');
    }
    return createLocalText(
        jsonEncode({'t': targetId, 'b': newText}), originName,
        kind: editKind);
  }

  Future<int> count() async => Sqflite.firstIntValue(await _db
    .rawQuery('SELECT COUNT(*) FROM messages WHERE kind<>?', [editKind]))!;
}
