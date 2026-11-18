import 'dart:io';

/// Installs a downloaded release over the running app (Windows and macOS).
///
/// Windows: runs the release's setup.exe, which stops the app, replaces it
/// and starts the new one.
/// macOS: a detached shell waits for this process to exit, swaps the .app
/// bundle and reopens it.
class SelfUpdate {
  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// Release file that carries the update for this platform.
  static String? get assetName {
    if (Platform.isWindows) return 'smoogi-share-setup.exe';
    if (Platform.isMacOS) return 'smoogi-share-macos.zip';
    return null;
  }

  /// Shell script run by macOS after the app quits. Arguments: pid, zip, app.
  static const macScript = r'''
while kill -0 "$1" 2>/dev/null; do sleep 0.5; done
t=$(mktemp -d) || exit 1
if ! ditto -x -k "$2" "$t" || [ ! -d "$t/smoogi_share.app" ]; then open "$3"; exit 1; fi
rm -rf "$3.old"
if ! mv "$3" "$3.old" || ! mv "$t/smoogi_share.app" "$3"; then
  [ ! -d "$3" ] && [ -d "$3.old" ] && mv "$3.old" "$3"
  open "$3"; exit 1
fi
rm -rf "$3.old" "$t"
xattr -cr "$3" 2>/dev/null
open "$3"
''';

  /// The .app bundle that contains the running executable, or null.
  static String? macAppPath(String executable) {
    final i = executable.indexOf('.app/');
    return i < 0 ? null : executable.substring(0, i + 4);
  }

  /// Starts the installer for [file]. The caller must exit the app right after.
  static Future<void> launch(File file) async {
    if (Platform.isWindows) {
      await Process.start(file.path, [], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      final app = macAppPath(Platform.resolvedExecutable);
      if (app == null) throw StateError('Not running from an .app bundle');
      await Process.start(
          '/bin/sh', ['-c', macScript, 'sh', '$pid', file.path, app],
          mode: ProcessStartMode.detached);
    } else {
      throw UnsupportedError('Automatic install is not available here');
    }
  }
}
