import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

/// What the system clipboard holds (injectable for tests).
abstract class ClipboardSource {
  Future<String?> text();
  Future<Uint8List?> image();
  Future<List<String>> files();
}

class SystemClipboard implements ClipboardSource {
  @override
  Future<String?> text() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  @override
  Future<Uint8List?> image() => Pasteboard.image;
  @override
  Future<List<String>> files() => Pasteboard.files();
}

/// File extension for image bytes, judged by their header.
String imageExtension(Uint8List b) {
  bool starts(List<int> m) =>
      b.length >= m.length && [for (var i = 0; i < m.length; i++) b[i] == m[i]].every((x) => x);
  if (starts([0x89, 0x50, 0x4E, 0x47])) return 'png';
  if (starts([0xFF, 0xD8, 0xFF])) return 'jpg';
  if (starts([0x42, 0x4D])) return 'bmp';
  if (starts([0x47, 0x49, 0x46])) return 'gif';
  return 'png';
}

String screenshotName(DateTime t, String ext) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'screenshot-${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}.$ext';
}

/// Paths of things to send for a paste, or empty when the clipboard holds
/// text (a normal text paste) or nothing usable. Pasted images are written
/// to [tempDir]; the caller deletes them after sending.
Future<List<String>> clipboardAttachments(ClipboardSource cb, Directory tempDir,
    {DateTime? now}) async {
  final text = await cb.text();
  if (text != null && text.isNotEmpty) return const [];
  final files = [for (final f in await cb.files()) if (File(f).existsSync()) f];
  if (files.isNotEmpty) return files;
  final img = await cb.image();
  if (img == null || img.isEmpty) return const [];
  await tempDir.create(recursive: true);
  final out = File('${tempDir.path}${Platform.pathSeparator}'
      '${screenshotName(now ?? DateTime.now(), imageExtension(img))}');
  await out.writeAsBytes(img, flush: true);
  return [out.path];
}

/// PNG bytes for any image the app can show (jpeg, webp, gif first frame...).
Future<Uint8List> imageAsPng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  if (data == null) throw StateError('Could not read the image');
  return data.buffer.asUint8List();
}

/// Puts the image file on the system clipboard as an image.
Future<void> copyImageToClipboard(File file) async {
  final png = await imageAsPng(await file.readAsBytes());
  await Pasteboard.writeImage(png);
}
