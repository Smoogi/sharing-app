import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The public releases-only repository the app checks.
const updateRepo = 'Smoogi/sharing-app';

class UpdateInfo {
  const UpdateInfo({required this.version, required this.notes, required this.url});
  final String version;
  final String notes;
  final String url;
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
    req.headers.set('Accept', 'application/vnd.github+json');
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
  UpdateService({JsonFetcher? fetch, this.repo = updateRepo})
      : _fetch = fetch ?? _httpGet;
  final JsonFetcher _fetch;
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
    return UpdateInfo(
      version: tag.replaceFirst(RegExp(r'^v'), ''),
      notes: (j['body'] is String ? j['body'] as String : '').trim(),
      url: url is String ? url : 'https://github.com/$repo/releases/latest',
    );
  }
}
