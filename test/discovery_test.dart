import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/transport/discovery.dart';

import 'helpers.dart';

void main() {
  test('beacon encode/parse and rejection of junk', () {
    final id = 'ab' * 16;
    expect(DiscoveryService.parseBeacon(DiscoveryService.encodeBeacon(id, 4000)),
        (id, 4000));
    expect(DiscoveryService.parseBeacon([1, 2, 3]), isNull);
    expect(DiscoveryService.parseBeacon('{"smoogi":1,"id":"x","port":1}'.codeUnits),
        isNull);
    expect(
        DiscoveryService.parseBeacon(
            '{"smoogi":1,"id":"${'a' * 32}","port":99999}'.codeUnits),
        isNull);
  });

  test('service receives beacons over UDP', () async {
    final seen = Completer<(String, String, int)>();
    final svc = DiscoveryService(
      deviceId: 'cd' * 16,
      portProvider: () => 1234,
      udpPort: 50123,
      targets: [InternetAddress.loopbackIPv4],
      onSeen: (id, host, port) {
        if (!seen.isCompleted) seen.complete((id, host, port));
      },
    );
    await svc.start();
    final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    sock.send(DiscoveryService.encodeBeacon('ef' * 16, 777),
        InternetAddress.loopbackIPv4, 50123);
    final hit = await seen.future.timeout(const Duration(seconds: 3));
    expect(hit.$1, 'ef' * 16);
    expect(hit.$3, 777);
    sock.close();
    await svc.stop();
  });

  test('paired device that changed port is found again via discovery', () async {
    final a = await makeNode('A');
    var b = await makeNode('B');
    await pairNodes(a, b);
    final oldPort = b.transport.port;
    await b.manager.stop();
    await eventually(() async => !a.manager.isOnline(b.identity.deviceId));

    b = await makeNodeOn(b); // new random port, B finds A itself; stop that:
    await b.manager.stop();
    await eventually(() async => !a.manager.isOnline(b.identity.deviceId));
    final b2 = await makeNodeOn(b);
    expect(b2.transport.port, isNot(oldPort));
    // Make sure A can only learn the address through discovery.
    await a.manager.stop();
    await a.peers.touch(b.identity.deviceId, host: '127.0.0.1', port: oldPort);
    await b2.manager.stop();
    await a.transport.start();
    await b2.transport.start();
    await a.manager.onDiscovered(b.identity.deviceId, '127.0.0.1', b2.transport.port);
    final peer = await a.peers.get(b.identity.deviceId);
    expect(peer!.lastPort, b2.transport.port);
  });
}
