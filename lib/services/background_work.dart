import 'dart:io';

import 'package:flutter/services.dart';

/// True when a connected peer has not yet acknowledged something we hold:
/// our vector (origin device -> highest seq) is ahead of what that peer
/// reported. Offline peers never count, so the service cannot be kept alive
/// by a device that is simply switched off.
bool hasUnackedForOnline(
  Map<String, int> local,
  Map<String, Map<String, int>> peerVectors,
  Set<String> onlinePeers,
) {
  for (final peer in onlinePeers) {
    final theirs = peerVectors[peer] ?? const <String, int>{};
    for (final e in local.entries) {
      if (e.value > (theirs[e.key] ?? 0)) return true;
    }
  }
  return false;
}

/// Android foreground service wrapper; a no-op everywhere else.
class BackgroundService {
  static const _ch = MethodChannel('smoogi/service');
  bool _running = false;
  String? _text;
  DateTime _lastFail = DateTime.fromMillisecondsSinceEpoch(0);

  bool get running => _running;

  /// Starts the service (or updates its notification text).
  Future<void> start(String text) async {
    if (!Platform.isAndroid) return;
    if (_running && _text == text) return;
    // Android refuses to start it from the background; do not hammer it.
    if (DateTime.now().difference(_lastFail) < const Duration(seconds: 5)) return;
    try {
      await _ch.invokeMethod<void>('start', {'text': text});
      _running = true;
      _text = text;
    } catch (_) {
      _lastFail = DateTime.now();
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid || !_running) return;
    _running = false;
    _text = null;
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
