import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/core/media_kind.dart';

void main() {
  test('kinds by mime and extension', () {
    expect(mediaKindOf('a.jpg', 'image/jpeg'), MediaKind.image);
    expect(mediaKindOf('a.webp', 'image/webp'), MediaKind.image);
    expect(mediaKindOf('a.MKV', 'application/octet-stream'), MediaKind.video);
    expect(mediaKindOf('a.webm', 'video/webm'), MediaKind.video);
    expect(mediaKindOf('a.mp4', 'video/mp4'), MediaKind.video);
    expect(mediaKindOf('a.mp3', 'audio/mpeg'), MediaKind.audio);
    expect(mediaKindOf('a.M4A', 'application/octet-stream'), MediaKind.audio);
    expect(mediaKindOf('a.flac', 'audio/flac'), MediaKind.other);
    expect(mediaKindOf('a.pdf', 'application/pdf'), MediaKind.other);
  });

  test('duration formatting', () {
    expect(formatDuration(const Duration(seconds: 125)), '2:05');
    expect(formatDuration(const Duration(seconds: 3725)), '1:02:05');
    expect(formatDuration(Duration.zero), '0:00');
  });
}
