import 'package:path/path.dart' as p;

/// 4chan-style filename helpers (used for images and gifs only).

/// How a long name is shown: names whose base is over 40 characters become
/// the first 35 characters + "(...)" + extension. Short names are untouched.
String shortDisplayName(String name) {
  final ext = p.extension(name);
  final base = ext.isEmpty ? name : name.substring(0, name.length - ext.length);
  if (base.length <= 40) return name;
  return '${base.substring(0, 35)}(...)$ext';
}

/// The name 4chan stores a file under: the post time in milliseconds since
/// the epoch plus the original extension, e.g. 1700000000123.jpg.
String timestampName(int createdAtMs, String originalName) {
  final ext = p.extension(originalName).toLowerCase();
  return '$createdAtMs${ext == '.jpeg' ? '.jpg' : ext}';
}
