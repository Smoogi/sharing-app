import 'dart:io';

import 'package:flutter/services.dart';

class SharedFile {
  SharedFile(this.path, this.name);
  final String path;
  final String name;
}

class SharedContent {
  SharedContent({this.text, this.subject, this.files = const []});
  final String? text;
  final String? subject;
  final List<SharedFile> files;
}

/// Receives content from Android's Share menu (see MainActivity.kt). On other
/// platforms this is a no-op.
class ShareReceiver {
  static const _channel = MethodChannel('smoogi/share');

  static Future<void> start(Future<void> Function(SharedContent) onShare) async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare') await onShare(_parse(call.arguments));
    });
    final initial = await _channel.invokeMethod<Object?>('getInitialShare');
    if (initial != null) await onShare(_parse(initial));
  }

  static SharedContent _parse(Object? raw) {
    final m = Map<String, dynamic>.from(raw as Map);
    return SharedContent(
      text: m['text'] as String?,
      subject: m['subject'] as String?,
      files: [
        for (final f in (m['files'] as List? ?? const []))
          SharedFile((f as Map)['path'] as String, f['name'] as String),
      ],
    );
  }
}
