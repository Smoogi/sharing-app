import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

/// Where the private seed can live outside the app's plain files
/// (Android Keystore-backed, Windows Credential Manager, macOS Keychain, ...).
abstract class SeedVault {
  Future<String?> read();
  Future<void> write(String value);
}

class SecureStorageVault implements SeedVault {
  SecureStorageVault([FlutterSecureStorage? s])
      : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'smoogi_identity_seed_v1';

  @override
  Future<String?> read() => _s.read(key: _key);

  @override
  Future<void> write(String value) => _s.write(key: _key, value: value);
}

/// Identity persistence. The Ed25519 seed is kept in the OS secure store when
/// available; the JSON file then only holds the device name. If the secure
/// store is unavailable (e.g. Linux without libsecret) the seed stays in the
/// app-private file as before. An existing file-based seed is migrated, and
/// only removed from the file after the vault read-back matches.
///
/// A vaulted identity whose key has vanished is an error, never silently
/// replaced (that would orphan every pairing).
class FileIdentityStore {
  FileIdentityStore(this.file, {this.vault});
  final File file;
  final SeedVault? vault;

  Future<bool> _vaultStore(String seedB64) async {
    final v = vault;
    if (v == null) return false;
    try {
      await v.write(seedB64);
      return await v.read() == seedB64;
    } catch (_) {
      return false;
    }
  }

  Future<DeviceIdentity> loadOrCreate({required String defaultName}) async {
    if (await file.exists()) {
      final Map<String, dynamic> j;
      try {
        j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        throw StateError('Identity file ${file.path} is unreadable.');
      }
      final name = j['name'] as String? ?? defaultName;
      String? seed = j['seed'] as String?;
      if (seed != null) {
        final id = await DeviceIdentity.fromSeed(unb64(seed), name);
        if (await _vaultStore(seed)) await _writeFile(name, null); // migrate
        return id;
      }
      if (j['vaulted'] == true) {
        try {
          seed = await vault?.read();
        } catch (_) {}
        if (seed == null) {
          throw StateError(
              'The device key is missing from the system keystore. Restore it or reset the app data folder (this requires re-pairing).');
        }
        return DeviceIdentity.fromSeed(unb64(seed), name);
      }
      throw StateError('Identity file ${file.path} has no key.');
    }
    final id = await DeviceIdentity.generate(name: defaultName);
    await save(id);
    return id;
  }

  Future<void> save(DeviceIdentity id) async {
    final seed = b64(await id.exportSeed());
    final vaulted = await _vaultStore(seed);
    await _writeFile(id.name, vaulted ? null : seed);
  }

  Future<void> _writeFile(String name, String? seed) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode({
          'name': name,
          if (seed != null) 'seed': seed else 'vaulted': true,
        }),
        flush: true);
    await tmp.rename(file.path);
  }
}
