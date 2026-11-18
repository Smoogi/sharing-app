import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/core/identity.dart';

class FakeVault implements SeedVault {
  String? value;
  bool broken = false;
  @override
  Future<String?> read() async {
    if (broken) throw StateError('no keystore');
    return value;
  }

  @override
  Future<void> write(String v) async {
    if (broken) throw StateError('no keystore');
    value = v;
  }
}

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('smoogi_id');
    file = File('${dir.path}/identity.json');
  });

  test('new identity: seed goes to vault, not the file; reload is stable', () async {
    final v = FakeVault();
    final id1 = await FileIdentityStore(file, vault: v)
        .loadOrCreate(defaultName: 'X');
    expect(await file.readAsString(), isNot(contains('"seed"')));
    expect(v.value, isNotNull);
    final id2 = await FileIdentityStore(file, vault: v)
        .loadOrCreate(defaultName: 'X');
    expect(id2.deviceId, id1.deviceId);
  });

  test('legacy file seed is migrated into the vault, same device id', () async {
    final legacy = await FileIdentityStore(file).loadOrCreate(defaultName: 'Old');
    expect(await file.readAsString(), contains('"seed"'));
    final v = FakeVault();
    final id = await FileIdentityStore(file, vault: v)
        .loadOrCreate(defaultName: 'Old');
    expect(id.deviceId, legacy.deviceId);
    expect(await file.readAsString(), isNot(contains('"seed"')));
    final again = await FileIdentityStore(file, vault: v)
        .loadOrCreate(defaultName: 'Old');
    expect(again.deviceId, legacy.deviceId);
  });

  test('broken keystore: seed stays in file, nothing lost', () async {
    final v = FakeVault()..broken = true;
    final id = await FileIdentityStore(file, vault: v)
        .loadOrCreate(defaultName: 'L');
    expect(jsonDecode(await file.readAsString())['seed'], isNotNull);
    final again = await FileIdentityStore(file, vault: v)
        .loadOrCreate(defaultName: 'L');
    expect(again.deviceId, id.deviceId);
  });

  test('vaulted identity with missing key is an error, never a new identity',
      () async {
    final v = FakeVault();
    await FileIdentityStore(file, vault: v).loadOrCreate(defaultName: 'L');
    v.value = null;
    await expectLater(
        FileIdentityStore(file, vault: v).loadOrCreate(defaultName: 'L'),
        throwsStateError);
  });
}
