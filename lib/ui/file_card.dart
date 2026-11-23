import 'dart:io';

import 'package:flutter/material.dart';

import '../core/file_names.dart';
import '../core/media_kind.dart';
import '../services/clipboard_paste.dart';
import 'media_viewer.dart';

import '../app/app_controller.dart';
import '../core/protocol.dart';
import '../data/attachment_store.dart';
import '../services/transfer_service.dart';

String formatSize(int bytes) {
  const u = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

/// 'image/jpeg' -> 'JPG', 'image/gif' -> 'GIF'.
String imageTypeLabel(String mime) {
  final t = mime.split('/').last.toUpperCase();
  return t == 'JPEG' ? 'JPG' : t;
}

IconData iconFor(FileMeta m) {
  if (m.isImage) return Icons.image;
  if (m.mime.startsWith('audio/')) return Icons.audiotrack;
  if (m.mime == 'application/pdf') return Icons.picture_as_pdf;
  if (m.mime == 'application/zip') return Icons.folder_zip;
  if (m.mime.contains('android.package')) return Icons.android;
  return Icons.insert_drive_file;
}

/// Body of a 'file' message: metadata always, bytes only if downloaded.
class FileBody extends StatelessWidget {
  const FileBody({super.key, required this.message, required this.controller});
  final ChatMessage message;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final meta = FileMeta.tryParse(message.body);
    if (meta == null) return const Text('Invalid file entry');
    final c = controller;
    final local = c.attachments[message.id];
    final st = c.transfers.states[message.id];
    final scheme = Theme.of(context).colorScheme;

    final kind = mediaKindOf(meta.name, meta.mime);

    Future<void> save() async {
      String text;
      try {
        final path = await c.saveToDownloads(message);
        text = path == null ? 'Could not find Downloads folder' : 'Saved to $path';
      } catch (e) {
        text = 'Could not save: $e';
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }

    // Right-click on desktop, long-press on phones.
    Future<void> menu(Offset at) async {
      if (local == null) return;
      final size = MediaQuery.of(context).size;
      final choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, size.width - at.dx, size.height - at.dy),
        items: [
          if (kind == MediaKind.image)
            const PopupMenuItem(value: 'copy', child: Text('Copy image')),
          const PopupMenuItem(value: 'save', child: Text('Save to Downloads')),
          const PopupMenuItem(value: 'open', child: Text('Open with another app')),
        ],
      );
      if (choice == 'copy') {
        String text;
        try {
          await copyImageToClipboard(File(local.path));
          text = 'Image copied';
        } catch (e) {
          text = 'Could not copy: $e';
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
        }
      }
      if (choice == 'save') await save();
      if (choice == 'open') await c.openFile(message);
    }

    Widget action;
    if (local != null) {
      // Media opens inside the app; everything else keeps an Open button.
      action = kind == MediaKind.other
          ? Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                  onPressed: () => c.openFile(message),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open')))
          : const SizedBox.shrink();
    } else if (st?.status == TransferStatus.downloading) {
      action = Row(children: [
        Expanded(child: LinearProgressIndicator(value: st!.fraction)),
        const SizedBox(width: 8),
        Text('${(st.fraction * 100).toStringAsFixed(0)}%'),
      ]);
    } else {
      final anyOnline = c.onlineIds.isNotEmpty;
      action = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.tonalIcon(
              onPressed: anyOnline ? () => c.download(message) : null,
              icon: Icon(
                  st?.status == TransferStatus.interrupted
                      ? Icons.refresh
                      : Icons.download,
                  size: 18),
              label: Text(st?.status == TransferStatus.interrupted
                  ? 'Resume'
                  : 'Download')),
          Text(
              anyOnline
                  ? 'Not downloaded yet'
                  : 'Not downloaded · no paired device online',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
        if (st != null && st.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(st.message!,
                style: TextStyle(
                    color: st.status == TransferStatus.failed
                        ? scheme.error
                        : scheme.onSurfaceVariant)),
          ),
      ]);
    }

    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (local != null && kind == MediaKind.image)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ImageViewerPage(
                    path: local.path, title: meta.name, onMenu: menu))),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(local.path),
                  height: 200,
                  cacheHeight: 400,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text('Preview unavailable')),
            ),
          ),
        ),
      if (local != null && kind == MediaKind.video)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) =>
                    VideoPage(path: local.path, title: meta.name, onMenu: menu))),
            child: Container(
              width: 240,
              height: 135,
              color: Colors.black,
              child: const Icon(Icons.play_circle_fill, color: Colors.white, size: 56),
            ),
          ),
        ),
      if (local != null && kind == MediaKind.audio) AudioInline(path: local.path),
      if (local != null && kind == MediaKind.image)
        // 4chan style: only size and type; tap to see the file name.
        Tooltip(
          message: meta.name,
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('${formatSize(meta.size)} ${imageTypeLabel(meta.mime)}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        )
      else
        Row(children: [
          Icon(iconFor(meta)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Tooltip(
                message: meta.name,
                child: SelectableText(
                    meta.isImage && c.settings.shortImageNames
                        ? shortDisplayName(meta.name)
                        : meta.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Text('${formatSize(meta.size)} · ${meta.mime}',
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
      const SizedBox(height: 8),
      action,
    ]);
    if (local == null) return body;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onSecondaryTapUp: (d) => menu(d.globalPosition),
      onLongPressStart: (d) => menu(d.globalPosition),
      child: body,
    );
  }
}
