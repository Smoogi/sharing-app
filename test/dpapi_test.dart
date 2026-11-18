import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/core/platform_vault.dart';

void main() {
  test('DPAPI vault round-trips and the file is not plaintext', () async {
    final dir = await Directory.systemTemp.createTemp('smoogi_dp');
    final v = DpapiVault(File('${dir.path}\seed.dpapi'));
    expect(await v.read(), isNull);
    await v.write('super-secret-seed-value');
    expect(await v.read(), 'super-secret-seed-value');
    final raw = await File('${dir.path}\seed.dpapi').readAsBytes();
    expect(String.fromCharCodes(raw), isNot(contains('super-secret')));
  }, skip: !Platform.isWindows);
}
