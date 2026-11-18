import 'dart:async';
import 'dart:io';

import 'package:smoogi_share/core/identity.dart';
import 'package:smoogi_share/data/app_database.dart';
import 'package:smoogi_share/data/attachment_store.dart';
import 'package:smoogi_share/data/message_repository.dart';
import 'package:smoogi_share/data/peer_repository.dart';
import 'package:smoogi_share/services/connection_manager.dart';
import 'package:smoogi_share/services/pairing_service.dart';
import 'package:smoogi_share/services/transfer_service.dart';
import 'package:smoogi_share/transport/secure_tcp_transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestNode {
  TestNode(this.identity, this.db, this.peers, this.messages, this.pairing,
      this.transport, this.manager, this.store, this.transfers);
  final DeviceIdentity identity;
  final Database db;
  final PeerRepository peers;
  final MessageRepository messages;
  final PairingService pairing;
  final SecureTcpTransport transport;
  final ConnectionManager manager;
  final AttachmentStore store;
  final TransferService transfers;
}

Future<TestNode> makeNode(String name,
    {String? dbPath, DeviceIdentity? identity, bool autoStart = true}) async {
  final id = identity ?? await DeviceIdentity.generate(name: name);
  final db = await AppDatabase.open(dbPath ?? inMemoryDatabasePath);
  final peers = PeerRepository(db);
  final msgs = MessageRepository(db, localDeviceId: id.deviceId);
  final pairing = PairingService();
  final transport =
      SecureTcpTransport(identity: id, preferredPort: 0, platform: 'test');
  final mgr = ConnectionManager(
    identity: id,
    transport: transport,
    peers: peers,
    messages: msgs,
    pairing: pairing,
    reconnectInterval: const Duration(milliseconds: 300),
    keepAliveInterval: const Duration(seconds: 5),
  );
  final dir = await Directory.systemTemp.createTemp('smoogi_att');
  final store = AttachmentStore(dir, db);
  final transfers = TransferService(
      manager: mgr,
      store: store,
      messages: msgs,
      chunkSize: 16 * 1024,
      stallTimeout: const Duration(seconds: 3));
  if (autoStart) await mgr.start();
  return TestNode(
      id, db, peers, msgs, pairing, transport, mgr, store, transfers);
}

Future<void> eventually(Future<bool> Function() cond,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('condition not met');
}

/// Simulates an app restart: new transport/manager over the same identity and
/// (still open) database.
Future<TestNode> makeNodeOn(TestNode old) async {
  final pairing = PairingService();
  final transport = SecureTcpTransport(
      identity: old.identity, preferredPort: 0, platform: 'test');
  final mgr = ConnectionManager(
    identity: old.identity,
    transport: transport,
    peers: old.peers,
    messages: old.messages,
    pairing: pairing,
    reconnectInterval: const Duration(milliseconds: 300),
    keepAliveInterval: const Duration(seconds: 5),
  );
  final transfers = TransferService(
      manager: mgr,
      store: old.store,
      messages: old.messages,
      chunkSize: 16 * 1024,
      stallTimeout: const Duration(seconds: 3));
  await mgr.start();
  return TestNode(old.identity, old.db, old.peers, old.messages, pairing,
      transport, mgr, old.store, transfers);
}

/// Pairs two nodes (auto-approving) and waits until both are online.
Future<void> pairNodes(TestNode a, TestNode b) async {
  a.manager.pairingRequests.listen((r) => r.approve());
  b.manager.pairingRequests.listen((r) => r.approve());
  a.pairing.setAccepting(true);
  await b.manager.pairWithAddress('127.0.0.1', a.transport.port);
  await eventually(() async =>
      a.manager.isOnline(b.identity.deviceId) &&
      b.manager.isOnline(a.identity.deviceId));
}
