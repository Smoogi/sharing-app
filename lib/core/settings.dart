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

  /// Images and gifs: show long names shortened like 4chan (first 35
  /// characters + (...) + extension). The original name is kept in the data.
  bool shortImageNames = true;

  /// Images and gifs: save copies under a 4chan-style timestamp name
  /// (e.g. 1700000000123.jpg) instead of the original name.
  bool timestampImageNames = false;

  /// Desktop: the close button hides the window to the tray / menu bar and
  /// the app keeps syncing. On by default.
  bool keepInTray = true;

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
          if (j['shortImageNames'] is bool) s.shortImageNames = j['shortImageNames'];
          if (j['timestampImageNames'] is bool) {
            s.timestampImageNames = j['timestampImageNames'];
          }
          if (j['keepInTray'] is bool) s.keepInTray = j['keepInTray'];
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
      'shortImageNames': shortImageNames,
      'timestampImageNames': timestampImageNames,
      'keepInTray': keepInTray,
      'lastUpdateCheck': lastUpdateCheck,
    }));
  }
}
