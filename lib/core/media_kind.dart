import 'package:path/path.dart' as p;

enum MediaKind { image, video, audio, other }

const _videoExt = {'.mp4', '.mkv', '.webm'};
const _audioExt = {'.mp3', '.m4a'};

/// What the in-app viewer can show. Judged by the mime type the sender gave
/// and by the file extension (a sender may label an mkv as octet-stream).
MediaKind mediaKindOf(String name, String mime) {
  const images = {'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/bmp'};
  if (images.contains(mime)) return MediaKind.image;
  final ext = p.extension(name).toLowerCase();
  if (_videoExt.contains(ext) || mime == 'video/mp4' || mime == 'video/webm' || mime == 'video/x-matroska') {
    return MediaKind.video;
  }
  if (_audioExt.contains(ext) || mime == 'audio/mpeg' || mime == 'audio/mp4' || mime == 'audio/x-m4a') {
    return MediaKind.audio;
  }
  return MediaKind.other;
}

/// 125 -> "2:05", 3725 -> "1:02:05".
String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
