import 'dart:convert';
import 'dart:io';

/// Tiny JSON-backed user settings (no secrets here).
class AppSettings {
  AppSettings(this._file, {this.autoDownloadMaxMb = 10});
  final File _file;

  /// Files up to this size (MB) download automatically; 0 = never.
  int autoDownloadMaxMb;

  static Future<AppSettings> load(File file) async {
    final s = AppSettings(file);
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString());
        if (j is Map && j['autoDownloadMaxMb'] is int) {
          s.autoDownloadMaxMb = (j['autoDownloadMaxMb'] as int).clamp(0, 10000);
        }
      }
    } catch (_) {}
    return s;
  }

  Future<void> save() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode({'autoDownloadMaxMb': autoDownloadMaxMb}));
  }
}
