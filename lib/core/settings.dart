import 'dart:convert';
import 'dart:io';

/// Tiny JSON-backed user settings (no secrets here).
class AppSettings {
  AppSettings(this._file, {this.autoDownloadMaxMb = 10});
  final File _file;

  /// Files up to this size (MB) download automatically; 0 = never.
  int autoDownloadMaxMb;

  /// Check GitHub for a new version at most once a day. Off by default.
  bool autoUpdateCheck = false;

  /// Epoch ms of the last update check (0 = never).
  int lastUpdateCheck = 0;

  static Future<AppSettings> load(File file) async {
    final s = AppSettings(file);
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString());
        if (j is Map) {
          if (j['autoDownloadMaxMb'] is int) {
            s.autoDownloadMaxMb = (j['autoDownloadMaxMb'] as int).clamp(0, 10000);
          }
          if (j['autoUpdateCheck'] is bool) s.autoUpdateCheck = j['autoUpdateCheck'];
          if (j['lastUpdateCheck'] is int) s.lastUpdateCheck = j['lastUpdateCheck'];
        }
      }
    } catch (_) {}
    return s;
  }

  Future<void> save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode({
      'autoDownloadMaxMb': autoDownloadMaxMb,
      'autoUpdateCheck': autoUpdateCheck,
      'lastUpdateCheck': lastUpdateCheck,
    }));
  }
}
