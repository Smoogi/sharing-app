import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'identity.dart';

/// OS-protected storage for the identity seed, without third-party plugins.
///
///  - Android: AES-GCM key inside the Android Keystore (MainActivity.kt).
///  - Windows: DPAPI (CryptProtectData), bound to the Windows user account.
///  - Linux / macOS: none yet -> the seed stays in the app-private file
///    (TODO: libsecret / Keychain).
class PlatformVault {
  static SeedVault? create(Directory dataDir) {
    if (Platform.isAndroid) return AndroidKeystoreVault();
    if (Platform.isWindows) {
      return DpapiVault(File('${dataDir.path}\\identity.seed.dpapi'));
    }
    return null;
  }
}

class AndroidKeystoreVault implements SeedVault {
  static const _ch = MethodChannel('smoogi/vault');

  @override
  Future<String?> read() => _ch.invokeMethod<String>('read');

  @override
  Future<void> write(String value) => _ch.invokeMethod('write', value);
}

// --- Windows DPAPI -------------------------------------------------------------

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _ProtectC = Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _ProtectD = int Function(Pointer<_DataBlob>, Pointer<Utf16>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _UnprotectC = Int32 Function(Pointer<_DataBlob>,
    Pointer<Pointer<Utf16>>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>,
    Uint32, Pointer<_DataBlob>);
typedef _UnprotectD = int Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _FreeC = Pointer<Void> Function(Pointer<Void>);
typedef _FreeD = Pointer<Void> Function(Pointer<Void>);

class DpapiVault implements SeedVault {
  DpapiVault(this.file);
  final File file;

  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protect =
      _crypt32.lookupFunction<_ProtectC, _ProtectD>('CryptProtectData');
  static final _unprotect =
      _crypt32.lookupFunction<_UnprotectC, _UnprotectD>('CryptUnprotectData');
  static final _localFree =
      _kernel32.lookupFunction<_FreeC, _FreeD>('LocalFree');

  static const _uiForbidden = 0x1;

  Uint8List _transform(Uint8List input, {required bool protect}) {
    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    final buf = calloc<Uint8>(input.isEmpty ? 1 : input.length);
    try {
      buf.asTypedList(input.length).setAll(0, input);
      inBlob.ref.cbData = input.length;
      inBlob.ref.pbData = buf;
      final ok = protect
          ? _protect(inBlob, nullptr, nullptr, nullptr, nullptr, _uiForbidden,
              outBlob)
          : _unprotect(inBlob, nullptr, nullptr, nullptr, nullptr, _uiForbidden,
              outBlob);
      if (ok == 0) throw StateError('DPAPI call failed');
      final out = Uint8List.fromList(
          outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
      _localFree(outBlob.ref.pbData.cast());
      return out;
    } finally {
      calloc.free(buf);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  @override
  Future<String?> read() async {
    if (!await file.exists()) return null;
    return utf8.decode(_transform(await file.readAsBytes(), protect: false));
  }

  @override
  Future<void> write(String value) async {
    final blob =
        _transform(Uint8List.fromList(utf8.encode(value)), protect: true);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(blob, flush: true);
    await tmp.rename(file.path);
  }
}
