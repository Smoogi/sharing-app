import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The public releases-only repository the app checks.
const updateRepo = 'Smoogi/sharing-app';

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.url,
    this.assets = const {},
  });
  final String version;
  final String notes;
  final String url;

  /// Release file name -> download URL.
  final Map<String, String> assets;
}

/// Opens a byte stream for a URL (injectable for tests).
typedef ByteOpener = Future<(Stream<List<int>>, int?)> Function(Uri url);

Future<(Stream<List<int>>, int?)> _httpOpen(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final req = await client.getUrl(url);
  req.headers.set('User-Agent', 'smoogi-share-update-check');
  final res = await req.close();
  if (res.statusCode != 200) {
    client.close(force: true);
    throw HttpException('Download failed: server answered ${res.statusCode}');
  }
  final len = res.contentLength >= 0 ? res.contentLength : null;
  return (res.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
    handleDone: (sink) {
      client.close();
      sink.close();
    },
  )), len);
}

/// Parses "v1.2.3", "1.2.3+45" -> [1,2,3]; null when it is not a version.
List<int>? parseVersion(String v) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(v.trim());
  if (m == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

/// True when [latest] is strictly newer than [current].
bool isNewerVersion(String latest, String current) {
  final a = parseVersion(latest), b = parseVersion(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

typedef JsonFetcher = Future<String> Function(Uri url);

Future<String> _httpGet(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(url);
    if (url.host == 'api.github.com') {
      req.headers.set('Accept', 'application/vnd.github+json');
    }
    req.headers.set('User-Agent', 'smoogi-share-update-check');
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('GitHub answered ${res.statusCode}');
    }
    return await res.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

/// Asks GitHub for the latest published release. Downloads and installs
/// nothing; the user opens the release page and installs it themselves.
class UpdateService {
  UpdateService({JsonFetcher? fetch, ByteOpener? open, this.repo = updateRepo})
      : _fetch = fetch ?? _httpGet,
        _open = open ?? _httpOpen;
  final JsonFetcher _fetch;
  final ByteOpener _open;
  final String repo;

  /// The newer release, or null when [currentVersion] is up to date.
  /// Throws when the check itself fails (offline, rate limit, bad reply).
  Future<UpdateInfo?> check(String currentVersion) async {
    final body =
        await _fetch(Uri.https('api.github.com', '/repos/$repo/releases/latest'));
    final j = jsonDecode(body);
    if (j is! Map || j['draft'] == true || j['prerelease'] == true) return null;
    final tag = j['tag_name'];
    if (tag is! String || parseVersion(tag) == null) {
      throw const FormatException('Unexpected reply from GitHub');
    }
    if (!isNewerVersion(tag, currentVersion)) return null;
    final url = j['html_url'];
    final assets = <String, String>{};
    if (j['assets'] is List) {
      for (final a in j['assets'] as List) {
        if (a is Map && a['name'] is String && a['browser_download_url'] is String) {
          assets[a['name'] as String] = a['browser_download_url'] as String;
        }
      }
    }
    return UpdateInfo(
      assets: assets,
      version: tag.replaceFirst(RegExp(r'^v'), ''),
      notes: (j['body'] is String ? j['body'] as String : '').trim(),
      url: url is String ? url : 'https://github.com/$repo/releases/latest',
    );
  }

  /// Downloads release file [name] into [dir] and checks it against the
  /// release's `<name>.sha256` file. Deletes the file and throws on mismatch.
  Future<File> download(UpdateInfo info, String name, Directory dir,
      {void Function(double fraction)? onProgress}) async {
    final url = info.assets[name];
    final shaUrl = info.assets['$name.sha256'];
    if (url == null || shaUrl == null) {
      throw StateError('$name is not attached to this release yet');
    }
    final expected = RegExp(r'[0-9a-fA-F]{64}')
        .firstMatch(await _fetch(Uri.parse(shaUrl)))
        ?.group(0)
        ?.toLowerCase();
    if (expected == null) throw const FormatException('Missing checksum');
    await dir.create(recursive: true);
    final out = File('${dir.path}${Platform.pathSeparator}$name');
    final (stream, total) = await _open(Uri.parse(url));
    final sink = out.openWrite();
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var got = 0;
    try {
      await for (final chunk in stream) {
        sink.add(chunk);
        hasher.add(chunk);
        got += chunk.length;
        if (total != null && total > 0) onProgress?.call(got / total);
      }
      hasher.close();
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await out.exists()) await out.delete();
      rethrow;
    }
    if (digestSink.hex != expected) {
      await out.delete();
      throw const FormatException('Checksum mismatch, download discarded');
    }
    return out;
  }
}

class _DigestSink implements Sink<Digest> {
  String hex = '';
  @override
  void add(Digest d) => hex = d.toString();
  @override
  void close() {}
}
