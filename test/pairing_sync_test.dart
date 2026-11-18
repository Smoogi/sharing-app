import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/services/connection_manager.dart';
import 'package:smoogi_share/services/pairing_service.dart';

import 'helpers.dart';

void autoDecide(TestNode n, bool approve) {
  n.manager.pairingRequests.listen((r) => approve ? r.approve() : r.reject());
}

void main() {
  test('manual pairing needs approval on both sides, then syncs both ways',
      () async {
    final a = await makeNode('Alpha');
    final b = await makeNode('Beta');
    final aReq = <PairingRequest>[];
    final bReq = <PairingRequest>[];
    a.manager.pairingRequests.listen((r) {
      aReq.add(r);
      r.approve();
    });
    b.manager.pairingRequests.listen((r) {
      bReq.add(r);
      r.approve();
    });

    // History created before pairing must sync after it.
    await a.messages.createLocalText('written before pairing', 'Alpha');

    a.pairing.setAccepting(true);
    await b.manager.pairWithAddress('127.0.0.1', a.transport.port);

    await eventually(() async =>
        (await a.peers.all()).length == 1 && (await b.peers.all()).length == 1);
    expect(aReq.single.sas, bReq.single.sas);
    expect(aReq.single.requiresSasComparison, isTrue);

    await eventually(() async => (await b.messages.count()) == 1);

    await b.manager.sendText('hello from beta\nsecond line');
    await a.manager.sendText('hello from alpha');
    await eventually(() async =>
        (await a.messages.count()) == 3 && (await b.messages.count()) == 3);
    final ha = (await a.messages.recent()).map((m) => m.id).toList();
    final hb = (await b.messages.recent()).map((m) => m.id).toList();
    expect(ha, hb);

    // Delivery acknowledgements reach the sender.
    await eventually(() async {
      final v = (await a.peers.vectors())[b.identity.deviceId];
      return v != null && v[a.identity.deviceId] == 2;
    });
  });

  test('unknown device is refused when not in pairing mode', () async {
    final a = await makeNode('Alpha');
    final b = await makeNode('Beta');
    var prompted = false;
    a.manager.pairingRequests.listen((_) => prompted = true);
    final notice = b.manager.notices.first;
    await b.manager.pairWithAddress('127.0.0.1', a.transport.port);
    expect(await notice.timeout(const Duration(seconds: 5)),
        contains('not in pairing mode'));
    expect(prompted, isFalse);
    expect(await a.peers.all(), isEmpty);
    expect(await b.peers.all(), isEmpty);
  });

  test('rejecting on either side stores nothing', () async {
    final a = await makeNode('Alpha');
    final b = await makeNode('Beta');
    autoDecide(a, true);
    autoDecide(b, false);
    a.pairing.setAccepting(true);
    await b.manager.pairWithAddress('127.0.0.1', a.transport.port);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await a.peers.all(), isEmpty);
    expect(await b.peers.all(), isEmpty);
    await a.messages.createLocalText('secret', 'Alpha');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(await b.messages.count(), 0);
  });

  test('QR pairing: scanner pins key, displayer approves without SAS', () async {
    final a = await makeNode('Alpha');
    final b = await makeNode('Beta');
    PairingRequest? shown;
    a.manager.pairingRequests.listen((r) {
      shown = r;
      r.approve();
    });
    a.pairing.setAccepting(true);
    final qr = PairingQrPayload(
      deviceId: a.identity.deviceId,
      publicKey: a.identity.publicKey,
      name: 'Alpha',
      addresses: ['127.0.0.1'],
      port: a.transport.port,
      token: a.pairing.newToken(),
    );
    await b.manager.pairWithQr(qr);
    await eventually(() async =>
        (await a.peers.all()).length == 1 && (await b.peers.all()).length == 1);
    expect(shown!.requiresSasComparison, isFalse);
  });

  test('QR with a different device key (MITM/impostor) is refused', () async {
    final a = await makeNode('Alpha');
    final b = await makeNode('Beta');
    final victimLike = await makeNode('Victim', autoStart: false);
    a.pairing.setAccepting(true);
    final qr = PairingQrPayload(
      deviceId: victimLike.identity.deviceId,
      publicKey: victimLike.identity.publicKey, // not Alpha's key
      name: 'Victim',
      addresses: ['127.0.0.1'],
      port: a.transport.port,
      token: a.pairing.newToken(),
    );
    await expectLater(b.manager.pairWithQr(qr), throwsA(anything));
    expect(await b.peers.all(), isEmpty);
  });

  test('reconnect after restart: offline messages are delivered, no duplicates',
      () async {
    final a = await makeNode('Alpha');
    var b = await makeNode('Beta');
    autoDecide(a, true);
    autoDecide(b, true);
    a.pairing.setAccepting(true);
    await b.manager.pairWithAddress('127.0.0.1', a.transport.port);
    await eventually(() async => a.manager.isOnline(b.identity.deviceId));

    // Beta goes away (app closed).
    await b.manager.stop();
    await eventually(() async => !a.manager.isOnline(b.identity.deviceId));

    // Both create messages independently while offline.
    await a.messages.createLocalText('alpha offline 1', 'Alpha');
    await a.manager.sendText('alpha offline 2');
    await b.messages.createLocalText('beta offline 1', 'Beta');
    expect(await b.messages.count(), 1);

    // Beta restarts (same identity + database), finds Alpha by saved address.
    b = await makeNodeOn(b);
    await eventually(() async =>
        (await a.messages.count()) == 3 && (await b.messages.count()) == 3);
    expect((await a.messages.recent()).map((m) => m.id).toSet(),
        (await b.messages.recent()).map((m) => m.id).toSet());
    // Several more sync rounds must not create duplicates.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(await a.messages.count(), 3);
  });

  test('three devices converge through relay', () async {
    final a = await makeNode('A');
    final b = await makeNode('B');
    final c = await makeNode('C');
    for (final n in [a, b, c]) {
      autoDecide(n, true);
    }
    a.pairing.setAccepting(true);
    await b.manager.pairWithAddress('127.0.0.1', a.transport.port);
    await eventually(() async => (await b.peers.all()).length == 1);
    await c.manager.pairWithAddress('127.0.0.1', a.transport.port);
    await eventually(() async => (await c.peers.all()).length == 1);
    // B and C never paired with each other; A relays.
    await eventually(() async =>
        a.manager.isOnline(b.identity.deviceId) &&
        a.manager.isOnline(c.identity.deviceId));
    await b.manager.sendText('from B');
    await eventually(() async => (await c.messages.count()) == 1);
    await c.manager.sendText('from C');
    await eventually(() async =>
        (await b.messages.count()) == 2 && (await a.messages.count()) == 2);
  });

  test('device that lost trust is told, not silently connected', () async {
    final a = await makeNode('Alpha');
    final b = await makeNode('Beta');
    autoDecide(a, true);
    autoDecide(b, true);
    a.pairing.setAccepting(true);
    await b.manager.pairWithAddress('127.0.0.1', a.transport.port);
    await eventually(() async => b.manager.isOnline(a.identity.deviceId));
    // Alpha removes Beta; Beta still trusts Alpha.
    await a.manager.removePeer(b.identity.deviceId);
    await a.messages.createLocalText('after removal', 'Alpha');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await b.messages.count(), 0);
    expect(a.manager.isOnline(b.identity.deviceId), isFalse);
  });
}

