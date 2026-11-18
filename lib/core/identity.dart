import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'bytes.dart';

final _ed25519 = Ed25519();

/// Persistent device identity: an Ed25519 key pair. The device id is derived
/// from the public key (first 16 bytes of SHA-256, hex), so an id can never be
/// claimed without the matching key.
class DeviceIdentity {
  DeviceIdentity._(this._keyPair, this.publicKey, this.deviceId, this.name);

  final SimpleKeyPair _keyPair;
  final Uint8List publicKey;
  final String deviceId;
  String name;

  static Future<DeviceIdentity> generate({required String name}) async =>
      _fromKeyPair(await _ed25519.newKeyPair(), name);

  static Future<DeviceIdentity> fromSeed(Uint8List seed, String name) async =>
      _fromKeyPair(await _ed25519.newKeyPairFromSeed(seed), name);

  static Future<DeviceIdentity> _fromKeyPair(
      SimpleKeyPair kp, String name) async {
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return DeviceIdentity._(kp, pub, await deviceIdFor(pub), name);
  }

  static Future<String> deviceIdFor(List<int> publicKey) async =>
      toHex((await sha256(publicKey)).sublist(0, 16));

  Future<Uint8List> exportSeed() async =>
      Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());

  Future<Uint8List> sign(List<int> data) async => Uint8List.fromList(
      (await _ed25519.sign(data, keyPair: _keyPair)).bytes);

  static Future<bool> verify(
      List<int> publicKey, List<int> data, List<int> signature) async {
    return await _ed25519.verify(
      data,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  /// Short human-readable fingerprint, e.g. "a1b2 c3d4 e5f6".
  String get fingerprint => fingerprintOf(deviceId);

  static String fingerprintOf(String deviceId) {
    final s = deviceId.substring(0, 12);
    return [for (var i = 0; i < 12; i += 4) s.substring(i, i + 4)].join(' ');
  }
}

/// Stores the identity in a JSON file inside the app-private directory.
///
/// LIMITATION: the seed is stored unencrypted in app-private storage (relies
/// on OS sandboxing). TODO: move the seed to Android Keystore / Windows DPAPI /
/// macOS Keychain (e.g. flutter_secure_storage) in a later milestone.
class FileIdentityStore {
  FileIdentityStore(this.file);
  final File file;

  Future<DeviceIdentity> loadOrCreate({required String defaultName}) async {
    if (await file.exists()) {
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        return await DeviceIdentity.fromSeed(
            unb64(j['seed'] as String), j['name'] as String? ?? defaultName);
      } catch (_) {
        // Corrupt identity file: do NOT silently replace it.
        throw StateError('Identity file ${file.path} is unreadable.');
      }
    }
    final id = await DeviceIdentity.generate(name: defaultName);
    await save(id);
    return id;
  }

  Future<void> save(DeviceIdentity id) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode({'seed': b64(await id.exportSeed()), 'name': id.name}),
        flush: true);
    await tmp.rename(file.path);
  }
}
