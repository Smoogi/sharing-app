import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/bytes.dart';
import '../core/protocol.dart';

/// Metadata of a shared file; this is what syncs automatically (as the body
/// of a message with kind 'file').
class FileMeta {
  const FileMeta(
      {required this.name,
      required this.size,
      required this.sha256,
      required this.mime});
  final String name;
  final int size;
  final String sha256; // hex
  final String mime;

  String toBody() =>
      jsonEncode({'name': name, 'size': size, 'sha256': sha256, 'mime': mime});

  bool get isImage => const {'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/bmp'}
      .contains(mime);

  static FileMeta? tryParse(String body) {
    try {
      return parse(body);
    } catch (_) {
      return null;
    }
  }

  static FileMeta parse(String body) {
    final j = jsonDecode(body);
    if (j is! Map) throw ProtocolException('bad file meta');
    final size = j['size'];
    final hash = j['sha256'];
    if (size is! int || size < 0) throw ProtocolException('bad file size');
    if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw ProtocolException('bad file hash');
    }
    return FileMeta(
      name: sanitizeFileName(j['name'] is String ? j['name'] as String : 'file'),
      size: size,
      sha256: hash,
      mime: j['mime'] is String && (j['mime'] as String).length < 100
          ? j['mime'] as String
          : 'application/octet-stream',
    );
  }
}

/// Peers are trusted, but names still must never escape the attachment dir.
String sanitizeFileName(String name) {
  var n = name.split(RegExp(r'[\\/]')).last;
  n = n.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_').trim();
  n = n.replaceAll(RegExp(r'^\.+'), '_');
  if (n.isEmpty) n = 'file';
  if (n.length > 120) {
    final ext = p.extension(n);
    n = n.substring(0, 120 - (ext.length > 12 ? 0 : ext.length)) +
        (ext.length > 12 ? '' : ext);
  }
  return n;
}

String guessMime(String name) {
  switch (p.extension(name).toLowerCase()) {
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.bmp':
      return 'image/bmp';
    case '.pdf':
      return 'application/pdf';
    case '.zip':
      return 'application/zip';
    case '.apk':
      return 'application/vnd.android.package-archive';
    case '.txt':
    case '.log':
      return 'text/plain';
    case '.mp3':
      return 'audio/mpeg';
    case '.m4a':
      return 'audio/mp4';
    case '.wav':
      return 'audio/wav';
    default:
      return 'application/octet-stream';
  }
}

Future<String> sha256OfFile(File f) async {
  final sink = Sha256().newHashSink();
  await for (final chunk in f.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  return toHex((await sink.hash()).bytes);
}

class LocalAttachment {
  const LocalAttachment(this.messageId, this.path, this.size);
  final String messageId;
  final String path;
  final int size;
}

/// Application-managed file storage: `<root>/<messageId>/<name>`. One folder
/// per message, so two files with the same name can never overwrite each
/// other. Incoming data goes to `<name>.part` and is only renamed after the
/// SHA-256 matches.
class AttachmentStore {
  AttachmentStore(this.root, this._db);
  final Directory root;
  final Database _db;

  static String _safeId(String id) =>
      RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(id)
          ? id
          : toHex(utf8.encode(id)).substring(0, 32);

  Directory dirFor(String messageId) =>
      Directory(p.join(root.path, _safeId(messageId)));

  File partFileFor(String messageId, FileMeta meta) =>
      File(p.join(dirFor(messageId).path, '${meta.name}.part'));

  File finalFileFor(String messageId, FileMeta meta) =>
      File(p.join(dirFor(messageId).path, meta.name));

  Future<LocalAttachment?> get(String messageId) async {
    final r = await _db
        .query('attachments', where: 'message_id=?', whereArgs: [messageId]);
    if (r.isEmpty) return null;
    final path = r.first['path'] as String;
    if (!await File(path).exists()) return null; // deleted externally
    return LocalAttachment(messageId, path, r.first['size'] as int);
  }

  Future<Map<String, LocalAttachment>> all() async {
    final out = <String, LocalAttachment>{};
    for (final r in await _db.query('attachments')) {
      out[r['message_id'] as String] = LocalAttachment(
          r['message_id'] as String, r['path'] as String, r['size'] as int);
    }
    return out;
  }

  /// Streams [src] into a staging file while hashing (no whole-file memory
  /// use). Returns the staged file and its metadata; call [commitStaged]
  /// once the message id exists.
  Future<({File staged, FileMeta meta})> stage(File src, {String? name}) async {
    final fileName = sanitizeFileName(name ?? p.basename(src.path));
    await root.create(recursive: true);
    final staged = File(p.join(root.path,
        '.staging-${DateTime.now().microsecondsSinceEpoch}-${fileName.hashCode.abs()}'));
    final sink = Sha256().newHashSink();
    final out = staged.openWrite();
    var size = 0;
    try {
      await for (final chunk in src.openRead()) {
        sink.add(chunk);
        out.add(chunk);
        size += chunk.length;
      }
      await out.flush();
      await out.close();
    } catch (_) {
      await out.close().catchError((_) {});
      if (await staged.exists()) await staged.delete();
      rethrow;
    }
    sink.close();
    return (
      staged: staged,
      meta: FileMeta(
        name: fileName,
        size: size,
        sha256: toHex((await sink.hash()).bytes),
        mime: guessMime(fileName),
      )
    );
  }

  Future<void> commitStaged(String messageId, File staged, FileMeta meta) async {
    await dirFor(messageId).create(recursive: true);
    final dest = finalFileFor(messageId, meta);
    await staged.rename(dest.path).catchError((_) async {
      await staged.copy(dest.path); // cross-volume fallback
      await staged.delete();
      return dest;
    });
    await register(messageId, dest.path, meta.size);
  }

  Future<void> register(String messageId, String path, int size) =>
      _db.insert(
          'attachments',
          {
            'message_id': messageId,
            'path': path,
            'size': size,
            'stored_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);

  /// Verifies and promotes a completed `.part` file. Returns false (and
  /// deletes the part) if size or hash do not match.
  Future<bool> finalizeDownload(String messageId, FileMeta meta) async {
    final part = partFileFor(messageId, meta);
    if (!await part.exists() || await part.length() != meta.size) return false;
    if (await sha256OfFile(part) != meta.sha256) {
      await part.delete();
      return false;
    }
    final dest = finalFileFor(messageId, meta);
    if (await dest.exists()) await dest.delete();
    await part.rename(dest.path);
    await register(messageId, dest.path, meta.size);
    return true;
  }

  /// Copies a stored file to [targetDir] without overwriting anything
  /// ("name (1).ext" if needed). Returns the new path.
  Future<String> saveCopy(LocalAttachment a, Directory targetDir) async {
    await targetDir.create(recursive: true);
    final base = p.basenameWithoutExtension(a.path);
    final ext = p.extension(a.path);
    var dest = File(p.join(targetDir.path, '$base$ext'));
    for (var i = 1; await dest.exists(); i++) {
      dest = File(p.join(targetDir.path, '$base ($i)$ext'));
    }
    await File(a.path).copy(dest.path);
    return dest.path;
  }
}
