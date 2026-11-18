import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test('throughput of a 20 MB transfer over loopback (informational)', () async {
    final a = await makeNode('A');
    final b = await makeNode('B');
    await pairNodes(a, b);
    // default service chunk size (192 KB) is exercised via a fresh service
    a.transfers; 
    final dir = await Directory.systemTemp.createTemp('smoogi_tp');
    final f = File('${dir.path}/big.bin');
    final r = Random(1);
    await f.writeAsBytes(Uint8List.fromList(List.generate(20 * 1024 * 1024, (_) => r.nextInt(256))));
    final sent = await a.transfers.sendFile(f);
    await eventually(() async => (await b.messages.count()) == 1);
    final m = (await b.messages.recent()).firstWhere((x) => x.id == sent.id);
    final sw = Stopwatch()..start();
    await b.transfers.download(m);
    sw.stop();
    final att = await b.store.get(m.id);
    expect(att, isNotNull);
    // ignore: avoid_print
    print('20 MB in ${sw.elapsedMilliseconds} ms = '
        '${(20 / (sw.elapsedMilliseconds / 1000)).toStringAsFixed(1)} MB/s (debug VM)');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
