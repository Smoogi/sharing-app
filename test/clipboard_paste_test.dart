import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/services/clipboard_paste.dart';

class FakeClipboard implements ClipboardSource {
  FakeClipboard({this.t, this.img, this.f = const []});
  final String? t;
  final Uint8List? img;
  final List<String> f;
  @override
  Future<String?> text() async => t;
  @override
  Future<Uint8List?> image() async => img;
  @override
  Future<List<String>> files() async => f;
}

void main() {
  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);

  test('screenshot on the clipboard becomes a named png file', () async {
    final dir = await Directory.systemTemp.createTemp('smoogi_paste');
    final out = await clipboardAttachments(FakeClipboard(img: png), dir,
        now: DateTime(2026, 11, 19, 9, 5, 7));
    expect(out.single, endsWith('screenshot-20261119-090507.png'));
    expect(File(out.single).readAsBytesSync(), png);
  });

  test('text on the clipboard is a normal paste', () async {
    final dir = await Directory.systemTemp.createTemp('smoogi_paste');
    expect(await clipboardAttachments(FakeClipboard(t: 'hello', img: png), dir), isEmpty);
    expect(await clipboardAttachments(FakeClipboard(), dir), isEmpty);
  });

  test('copied files are sent as they are; missing ones are skipped', () async {
    final dir = await Directory.systemTemp.createTemp('smoogi_paste');
    final real = File('${dir.path}/a.txt')..writeAsStringSync('x');
    final out = await clipboardAttachments(
        FakeClipboard(f: [real.path, '${dir.path}/gone.txt']), dir);
    expect(out, [real.path]);
  });

  test('image type is detected from the header', () {
    expect(imageExtension(png), 'png');
    expect(imageExtension(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0])), 'jpg');
    expect(imageExtension(Uint8List.fromList([0x42, 0x4D, 0])), 'bmp');
    expect(imageExtension(Uint8List.fromList([9, 9])), 'png');
  });
}
