import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/services/self_update.dart';
import 'package:smoogi_share/services/update_service.dart';

void main() {
  final payload = List<int>.generate(300000, (i) => i % 251);
  final good = sha256.convert(payload).toString();

  UpdateService svc(String shaText, {List<int>? bytes}) => UpdateService(
        fetch: (u) async => shaText,
        open: (u) async => (
          Stream.fromIterable([
            for (var i = 0; i < payload.length; i += 65536)
              (bytes ?? payload).sublist(i, (i + 65536).clamp(0, payload.length))
          ]),
          payload.length
        ),
      );
  const info = UpdateInfo(version: '9.9.9', notes: '', url: 'u', assets: {
    'smoogi-share-setup.exe': 'https://x/setup.exe',
    'smoogi-share-setup.exe.sha256': 'https://x/setup.exe.sha256',
  });

  test('release assets are parsed from the API reply', () async {
    final u = await UpdateService(
        fetch: (_) async => jsonEncode({
              'tag_name': 'v9.9.9',
              'assets': [
                {'name': 'a.zip', 'browser_download_url': 'https://x/a.zip'}
              ]
            })).check('0.4.0');
    expect(u!.assets['a.zip'], 'https://x/a.zip');
  });

  test('download verifies the checksum and reports progress', () async {
    final dir = await Directory.systemTemp.createTemp('smoogi_dl');
    var last = 0.0;
    final f = await svc('$good  smoogi-share-setup.exe')
        .download(info, 'smoogi-share-setup.exe', dir, onProgress: (x) => last = x);
    expect(f.lengthSync(), payload.length);
    expect(last, 1.0);
  });

  test('checksum mismatch deletes the file and throws', () async {
    final dir = await Directory.systemTemp.createTemp('smoogi_dl');
    final bad = List<int>.of(payload)..[10] ^= 1;
    await expectLater(
        svc('$good  x', bytes: bad).download(info, 'smoogi-share-setup.exe', dir),
        throwsFormatException);
    expect(File('${dir.path}/smoogi-share-setup.exe').existsSync(), isFalse);
  });

  test('missing asset or checksum refuses', () async {
    final dir = await Directory.systemTemp.createTemp('smoogi_dl');
    await expectLater(
        svc(good).download(const UpdateInfo(version: '1', notes: '', url: ''),
            'smoogi-share-setup.exe', dir),
        throwsStateError);
    await expectLater(
        svc('no hash here').download(info, 'smoogi-share-setup.exe', dir),
        throwsFormatException);
  });

  test('mac app path comes from the executable path', () {
    expect(SelfUpdate.macAppPath('/Applications/smoogi_share.app/Contents/MacOS/smoogi_share'),
        '/Applications/smoogi_share.app');
    expect(SelfUpdate.macAppPath('/tmp/build/smoogi_share'), isNull);
  });
}
