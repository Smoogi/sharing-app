import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/core/protocol.dart';
import 'package:smoogi_share/data/attachment_store.dart';
import 'package:smoogi_share/services/transfer_service.dart';

import 'helpers.dart';

Future<File> tempFile(String name, int size) async {
  final dir = await Directory.systemTemp.createTemp('smoogi_src');
  final f = File('${dir.path}/$name');
  final r = Random(42);
  await f.writeAsBytes(
      Uint8List.fromList(List.generate(size, (_) => r.nextInt(256))));
  return f;
}

Future<ChatMessage> fileMessageOn(TestNode n, String id) async =>
    (await n.messages.recent()).firstWhere((m) => m.id == id);

void main() {
  test('metadata syncs automatically; bytes only on demand, hash verified',
      () async {
    final a = await makeNode('A');
    final b = await makeNode('B');
    await pairNodes(a, b);
    final src = await tempFile('log data.bin', 300000);
    final sent = await a.transfers.sendFile(src);

    await eventually(() async => (await b.messages.count()) == 1);
    final m = await fileMessageOn(b, sent.id);
    expect(m.kind, 'file');
    expect(await b.store.get(m.id), isNull, reason: 'not downloaded yet');

    await b.transfers.download(m);
    final att = await b.store.get(m.id);
    expect(att, isNotNull);
    expect(await File(att!.path).readAsBytes(), await src.readAsBytes());
    expect(b.transfers.states.containsKey(m.id), isFalse);
  });

  test('source offline: reported unavailable, never as success', () async {
    final a = await makeNode('A');
    final b = await makeNode('B');
    await pairNodes(a, b);
    final sent = await a.transfers.sendFile(await tempFile('x.bin', 1000));
    await eventually(() async => (await b.messages.count()) == 1);
    await a.manager.stop();
    await eventually(() async => !b.manager.isOnline(a.identity.deviceId));
    await b.transfers.download(await fileMessageOn(b, sent.id));
    expect(b.transfers.states[sent.id]!.status, TransferStatus.unavailable);
    expect(await b.store.get(sent.id), isNull);
  });

  test('corrupted source is rejected by hash check', () async {
    final a = await makeNode('A');
    final b = await makeNode('B');
    await pairNodes(a, b);
    final sent = await a.transfers.sendFile(await tempFile('c.bin', 20000));
    await eventually(() async => (await b.messages.count()) == 1);
    final att = (await a.store.get(sent.id))!;
    final bytes = await File(att.path).readAsBytes();
    bytes[100] ^= 0xff;
    await File(att.path).writeAsBytes(bytes);

    final m = await fileMessageOn(b, sent.id);
    await b.transfers.download(m);
    expect(await b.store.get(sent.id), isNull);
    expect(b.transfers.states[sent.id]!.status, TransferStatus.failed);
    final meta = FileMeta.parse(m.body);
    expect(await b.store.partFileFor(sent.id, meta).exists(), isFalse);
  });

  test('partial file on disk is resumed from its offset', () async {
    final a = await makeNode('A');
    final b = await makeNode('B');
    await pairNodes(a, b);
    final src = await tempFile('big.bin', 400000);
    final sent = await a.transfers.sendFile(src);
    await eventually(() async => (await b.messages.count()) == 1);
    final m = await fileMessageOn(b, sent.id);
    final meta = FileMeta.parse(m.body);

    await b.store.dirFor(m.id).create(recursive: true);
    final part = b.store.partFileFor(m.id, meta);
    await part.writeAsBytes((await src.readAsBytes()).sublist(0, 100000));

    await b.transfers.download(m);
    final att = await b.store.get(m.id);
    expect(att, isNotNull);
    expect(await File(att!.path).readAsBytes(), await src.readAsBytes());
    expect(await part.exists(), isFalse);
  });

  test('connection dropped mid-transfer -> interrupted, then resume completes',
      () async {
    final a = await makeNode('A');
    final b = await makeNode('B');
    await pairNodes(a, b);
    final src = await tempFile('drop.bin', 15000000);
    final sent = await a.transfers.sendFile(src);
    await eventually(() async => (await b.messages.count()) == 1);
    final m = await fileMessageOn(b, sent.id);

    final dl = b.transfers.download(m);
    await eventually(
        () async => (b.transfers.states[m.id]?.received ?? 0) > 50000);
    final old = b.manager.channelOf(a.identity.deviceId)!;
    await old.close();
    await dl;
    expect(b.transfers.states[m.id]!.status, TransferStatus.interrupted);
    expect(await b.store.get(m.id), isNull);

    await eventually(() async {
      final c = b.manager.channelOf(a.identity.deviceId);
      return c != null && c != old && !c.isClosed;
    });
    await b.transfers.download(m);
    final att = await b.store.get(m.id);
    if (att == null) {
      final st = b.transfers.states[m.id];
      fail('no file: ${st?.status} ${st?.message} recv=${st?.received}');
    }
    expect(await File(att.path).readAsBytes(), await src.readAsBytes());
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('relay: a device that already has the file can serve it', () async {
    final a = await makeNode('A');
    final b = await makeNode('B');
    final c = await makeNode('C');
    await pairNodes(a, b);
    await pairNodes(a, c);
    await eventually(() async => a.manager.onlinePeerIds.length == 2);
    final sent = await b.transfers.sendFile(await tempFile('r.bin', 5000));
    await eventually(() async =>
        (await c.messages.count()) == 1 && (await a.messages.count()) == 1);
    await a.transfers.download(await fileMessageOn(a, sent.id));
    expect(await a.store.get(sent.id), isNotNull);
    await c.transfers.download(await fileMessageOn(c, sent.id));
    expect(await c.store.get(sent.id), isNotNull); // served by A, not origin
  });

  test('file names cannot escape the attachment folder', () {
    expect(sanitizeFileName('../../etc/passwd'), 'passwd');
    expect(sanitizeFileName(r'..\..\win.ini'), 'win.ini');
    expect(sanitizeFileName('...hidden'), '_hidden');
    expect(sanitizeFileName(''), 'file');
    expect(sanitizeFileName('a<b>:c.txt'), 'a_b__c.txt');
  });

  test('same file name twice never overwrites', () async {
    final a = await makeNode('A');
    final m1 = await a.transfers.sendFile(await tempFile('same.txt', 10));
    final m2 = await a.transfers.sendFile(await tempFile('same.txt', 20));
    final p1 = (await a.store.get(m1.id))!.path;
    final p2 = (await a.store.get(m2.id))!.path;
    expect(p1, isNot(p2));
    expect(await File(p1).length(), 10);
    expect(await File(p2).length(), 20);
    final target = Directory.systemTemp.createTempSync();
    final c1 = await a.store.saveCopy((await a.store.get(m1.id))!, target);
    final c2 = await a.store.saveCopy((await a.store.get(m2.id))!, target);
    expect(c1, isNot(c2));
  });
}
