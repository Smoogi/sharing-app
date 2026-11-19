import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/settings.dart';

/// Loopback port used only to detect a second copy of the app.
const singleInstancePort = 47731;

/// Returns true when this process is the only instance. Otherwise it asks the
/// running one to show its window and returns false (the caller exits).
Future<bool> claimSingleInstance(void Function() onShow,
    {int port = singleInstancePort}) async {
  try {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    server.listen((s) {
      s.listen((_) => onShow(), onError: (_) {}, onDone: s.destroy);
    }, onError: (_) {});
    return true;
  } on SocketException {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(seconds: 2));
      s.add(const [1]);
      await s.flush();
      await s.close();
      return false;
    } catch (_) {
      // Port taken by something else: just run.
      return true;
    }
  }
}

/// Windows / macOS: the close button hides the window (the app keeps
/// syncing) and a tray / menu-bar icon brings it back or quits.
class DesktopShell with TrayListener, WindowListener {
  DesktopShell(this.settings);
  final AppSettings settings;

  static bool get supported => !kIsWeb && (Platform.isWindows || Platform.isMacOS);

  Future<void> init() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);
    await trayManager.setIcon(Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png');
    await trayManager.setToolTip('Smoogi Share');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'Open Smoogi Share'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
  }

  Future<void> show() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    await trayManager.destroy();
    await windowManager.destroy();
  }

  @override
  void onWindowClose() async {
    if (settings.keepInTray) {
      await windowManager.hide();
    } else {
      await quit();
    }
  }

  @override
  void onTrayIconMouseDown() => show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'open') show();
    if (item.key == 'quit') quit();
  }
}
