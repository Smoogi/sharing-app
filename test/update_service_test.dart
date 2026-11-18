import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/services/update_service.dart';

UpdateService svc(Map<String, Object?> json, [void Function(Uri)? seen]) =>
    UpdateService(fetch: (u) async {
      seen?.call(u);
      return jsonEncode(json);
    });

void main() {
  test('version comparison', () {
    expect(isNewerVersion('v0.5.0', '0.4.0'), isTrue);
    expect(isNewerVersion('0.4.1', '0.4.0+3200'), isTrue);
    expect(isNewerVersion('1.0.0', '0.9.9'), isTrue);
    expect(isNewerVersion('0.4.0', '0.4.0'), isFalse);
    expect(isNewerVersion('0.3.9', '0.4.0'), isFalse);
    expect(isNewerVersion('0.10.0', '0.9.0'), isTrue);
    expect(isNewerVersion('garbage', '0.4.0'), isFalse);
  });

  test('newer release is reported with notes and page', () async {
    Uri? asked;
    final u = await svc({
      'tag_name': 'v0.5.0',
      'body': 'New stuff ',
      'html_url': 'https://github.com/Smoogi/sharing-app/releases/tag/v0.5.0',
    }, (x) => asked = x)
        .check('0.4.0');
    expect(u!.version, '0.5.0');
    expect(u.notes, 'New stuff');
    expect(u.url, endsWith('v0.5.0'));
    expect(asked.toString(),
        'https://api.github.com/repos/Smoogi/sharing-app/releases/latest');
  });

  test('up to date, prerelease and draft give null', () async {
    expect(await svc({'tag_name': 'v0.4.0'}).check('0.4.0'), isNull);
    expect(await svc({'tag_name': 'v9.0.0', 'prerelease': true}).check('0.4.0'), isNull);
    expect(await svc({'tag_name': 'v9.0.0', 'draft': true}).check('0.4.0'), isNull);
  });

  test('bad replies and network errors throw', () async {
    await expectLater(svc({'tag_name': 'nightly'}).check('0.4.0'), throwsFormatException);
    await expectLater(
        UpdateService(fetch: (_) async => throw Exception('offline')).check('0.4.0'),
        throwsException);
  });
}
