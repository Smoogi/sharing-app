import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/core/protocol.dart';
import 'package:smoogi_share/data/app_database.dart';
import 'package:smoogi_share/data/message_repository.dart';
import 'package:smoogi_share/data/peer_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final a = 'a' * 32;
final b = 'b' * 32;

ChatMessage m(String dev, int seq, {String? id, String body = 'x'}) =>
    ChatMessage(
        id: id ?? '$dev-$seq',
        originDeviceId: dev,
        originName: dev.substring(0, 1),
        originSeq: seq,
        createdAt: 1000 + seq,
        kind: 'text',
        body: body);

void main() {
  late MessageRepository repo;
  setUp(() async {
    repo = MessageRepository(await AppDatabase.open(inMemoryDatabasePath),
        localDeviceId: a);
  });

  test('local messages get contiguous sequence numbers', () async {
    final m1 = await repo.createLocalText('one', 'A');
    final m2 = await repo.createLocalText('two', 'A');
    expect([m1.originSeq, m2.originSeq], [1, 2]);
    expect(await repo.vector(), {a: 2});
  });

  test('duplicate prevention: applying twice inserts once', () async {
    final r1 = await repo.apply([m(b, 1), m(b, 2)]);
    final r2 = await repo.apply([m(b, 1), m(b, 2)]);
    expect(r1.inserted.length, 2);
    expect(r2.inserted, isEmpty);
    expect(r2.duplicates, 2);
    expect(await repo.count(), 2);
  });

  test('gap: out-of-order message is not accepted, later fill works', () async {
    final r = await repo.apply([m(b, 2)]);
    expect(r.gaps, 1);
    expect(await repo.count(), 0);
    await repo.apply([m(b, 1), m(b, 2)]);
    expect(await repo.vector(), {b: 2});
  });

  test('conflicting content for same (origin,seq) never overwrites', () async {
    await repo.apply([m(b, 1, body: 'original')]);
    final r = await repo.apply([m(b, 1, id: 'other', body: 'evil')]);
    expect(r.conflicts, 1);
    final all = await repo.recent();
    expect(all.single.body, 'original');
  });

  test('sync reconciliation: independent offline histories converge', () async {
    final dbB = await AppDatabase.open(inMemoryDatabasePath);
    final repoB = MessageRepository(dbB, localDeviceId: b);
    await repo.createLocalText('a1', 'A');
    await repo.createLocalText('a2', 'A');
    await repoB.createLocalText('b1', 'B');

    Future<void> sync(MessageRepository from, MessageRepository to) async {
      final missing = await from.missingFor(await to.vector());
      await to.apply(missing);
    }

    await sync(repo, repoB);
    await sync(repoB, repo);
    await sync(repo, repoB); // idempotent second round
    final ha = (await repo.recent()).map((e) => e.id).toList();
    final hb = (await repoB.recent()).map((e) => e.id).toList();
    expect(ha.length, 3);
    expect(ha, hb);
    expect(await repo.vector(), await repoB.vector());
  });

  test('missingFor respects limit and ordering', () async {
    for (var i = 0; i < 10; i++) {
      await repo.createLocalText('m$i', 'A');
    }
    final part = await repo.missingFor({a: 3}, limit: 4);
    expect(part.map((e) => e.originSeq), [4, 5, 6, 7]);
  });

  test('search treats % and _ literally', () async {
    await repo.createLocalText('100% sure', 'A');
    await repo.createLocalText('something else', 'A');
    expect((await repo.recent(query: '100%')).length, 1);
    expect((await repo.recent(query: '_')).length, 0);
  });

  test('offline queue persistence: data survives reopen', () async {
    final dir = await Directory.systemTemp.createTemp('smoogi_db');
    final path = '${dir.path}/t.db';
    var db = await AppDatabase.open(path);
    var r = MessageRepository(db, localDeviceId: a);
    await r.createLocalText('unsent while offline', 'A');
    await PeerRepository(db).mergeVector(b, {a: 0});
    await db.close();

    db = await AppDatabase.open(path);
    r = MessageRepository(db, localDeviceId: a);
    expect((await r.recent()).single.body, 'unsent while offline');
    // Peer b has confirmed nothing, so the message is still pending for it.
    expect((await r.missingFor({})).length, 1);
    final next = await r.createLocalText('after restart', 'A');
    expect(next.originSeq, 2);
    await db.close();
    await dir.delete(recursive: true);
  });
}
