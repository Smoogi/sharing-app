import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/core/file_names.dart';

void main() {
  test('short names are untouched', () {
    expect(shortDisplayName('cat.jpg'), 'cat.jpg');
    expect(shortDisplayName('${'a' * 40}.png'), '${'a' * 40}.png');
  });

  test('long names become 35 chars + (...) + extension', () {
    final n = '${'abcdefghij' * 6}.gif';
    expect(shortDisplayName(n), '${'abcdefghij' * 3}abcde(...).gif');
  });

  test('no extension and dotted names', () {
    expect(shortDisplayName('x' * 50), '${'x' * 35}(...)');
    expect(shortDisplayName('${'y' * 45}.tar.gz'), '${'y' * 35}(...).gz'.replaceFirst('y' * 35, ('y' * 45 + '.tar').substring(0, 35)));
  });

  test('timestamp names keep the extension, lowercase, jpeg -> jpg', () {
    expect(timestampName(1700000000123, 'My Photo.PNG'), '1700000000123.png');
    expect(timestampName(1700000000123, 'a.jpeg'), '1700000000123.jpg');
    expect(timestampName(1700000000123, 'noext'), '1700000000123');
  });
}
