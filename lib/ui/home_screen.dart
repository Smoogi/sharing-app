import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_controller.dart';
import '../core/protocol.dart';
import '../data/attachment_store.dart';
import '../services/connection_manager.dart';
import 'devices_screen.dart';
import 'file_card.dart';

final _urlRe = RegExp(r'https?://[^\s<>"]+');

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _searchCtl = TextEditingController();
  bool _searching = false;
  final _subs = <StreamSubscription<dynamic>>[];
  int _lastCount = 0;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _subs.add(c.manager.pairingRequests.listen(_showPairing));
    _subs.add(c.manager.notices.listen((n) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(n)));
    }));
    c.addListener(_onChange);
  }

  void _onChange() {
    if (c.items.length != _lastCount) {
      _lastCount = c.items.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    for (final s in _subs) {
      s.cancel();
    }
    _input.dispose();
    _scroll.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    try {
      await c.sendText(text);
      _input.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _attach() async {
    final files = await openFiles();
    if (files.isEmpty) return;
    await _sendPaths(files.map((f) => f.path).toList());
  }

  Future<void> _sendPaths(List<String> paths) async {
    try {
      await c.sendFiles(paths);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not add file: $e')));
    }
  }

  bool _dragging = false;

  void _showPairing(PairingRequest req) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PairingDialog(request: req),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final online = c.onlineIds.length;
        return Scaffold(
          appBar: AppBar(
            title: _searching
                ? TextField(
                    controller: _searchCtl,
                    autofocus: true,
                    decoration: const InputDecoration(
                        hintText: 'Search history', border: InputBorder.none),
                    onChanged: c.search,
                  )
                : const Text('Smoogi Share'),
            actions: [
              IconButton(
                tooltip: 'Search',
                icon: Icon(_searching ? Icons.close : Icons.search),
                onPressed: () {
                  setState(() => _searching = !_searching);
                  if (!_searching) {
                    _searchCtl.clear();
                    c.search('');
                  }
                },
              ),
              IconButton(
                tooltip: 'Devices',
                icon: Badge(
                  isLabelVisible: online > 0,
                  label: Text('$online'),
                  child: const Icon(Icons.devices),
                ),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DevicesScreen(controller: c))),
              ),
            ],
          ),
          body: _dropWrap(Column(children: [
            Expanded(
              child: c.items.isEmpty
                  ? Center(
                      child: Text(
                          c.query.isEmpty
                              ? 'Nothing here yet.\nType below, or pair a device from the Devices screen.'
                              : 'No matches.',
                          textAlign: TextAlign.center),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: c.items.length,
                      itemBuilder: (_, i) =>
                          MessageCard(message: c.items[i], controller: c),
                    ),
            ),
            _composer(),
          ])),
        );
      },
    );
  }

  Widget _dropWrap(Widget child) {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return child;
    }
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        _sendPaths(d.files.map((f) => f.path).toList());
      },
      child: Stack(children: [
        child,
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.15),
                alignment: Alignment.center,
                child: const Text('Drop files to share',
                    style: TextStyle(fontSize: 24)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          IconButton(
              tooltip: 'Attach files',
              onPressed: _attach,
              icon: const Icon(Icons.attach_file)),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    _send,
              },
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  hintText: 'Message, note, link or log (Ctrl+Enter sends)',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
              tooltip: 'Send', onPressed: _send, icon: const Icon(Icons.send)),
        ]),
      ),
    );
  }
}

class MessageCard extends StatefulWidget {
  const MessageCard({super.key, required this.message, required this.controller});
  final ChatMessage message;
  final AppController controller;

  @override
  State<MessageCard> createState() => _MessageCardState();
}

class _MessageCardState extends State<MessageCard> {
  bool _expanded = false;
  static const _collapsedLines = 14;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final c = widget.controller;
    final cs = Theme.of(context).colorScheme;
    final mine = m.originDeviceId == c.identity.deviceId;
    final lines = '\n'.allMatches(m.body).length + 1;
    final long = lines > _collapsedLines;
    final urls = m.kind != 'text' ? <String>{} : _urlRe.allMatches(m.body).map((e) => e.group(0)!).toSet();
    final t = DateTime.fromMillisecondsSinceEpoch(m.createdAt, isUtc: true)
        .toLocal();
    final time =
        '${t.year}-${_2(t.month)}-${_2(t.day)} ${_2(t.hour)}:${_2(t.minute)}';
    final status = mine ? c.syncStatus(m) : null;

    return Card(
      color: mine ? cs.primaryContainer : cs.surfaceContainerHighest,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                '${mine ? 'This device' : m.originName} · $time'
                '${status != null ? ' · $status' : ''}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            IconButton(
              tooltip: 'Copy',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(
                    text: m.kind == 'file'
                        ? (FileMeta.tryParse(m.body)?.name ?? m.body)
                        : m.body));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Copied'),
                    duration: Duration(milliseconds: 900)));
              },
            ),
          ]),
          if (m.kind == 'file')
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 4),
              child: FileBody(message: m, controller: c),
            )
          else if (m.kind != 'text')
            Text('Unsupported item type "${m.kind}" (update the app)',
                style: const TextStyle(fontStyle: FontStyle.italic))
          else
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SelectableText(
                long && !_expanded
                    ? '${m.body.split('\n').take(_collapsedLines).join('\n')}\n…'
                    : m.body,
                style: lines > 3
                    ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
                    : null,
              ),
            ),
          if (long)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? 'Show less' : 'Show all $lines lines'),
            ),
          for (final u in urls)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(u, overflow: TextOverflow.ellipsis),
                onPressed: () =>
                    launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication),
              ),
            ),
        ]),
      ),
    );
  }

  String _2(int n) => n.toString().padLeft(2, '0');
}

class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key, required this.request});
  final PairingRequest request;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  @override
  void initState() {
    super.initState();
    // Closed automatically if the peer disconnects or the request times out.
    widget.request.decision.then((_) {
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return AlertDialog(
      title: Text(r.initiatedLocally ? 'Pair with ${r.peerName}?' : '${r.peerName} wants to pair'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Device: ${r.peerName} (${r.peerPlatform})'),
        const SizedBox(height: 12),
        if (r.requiresSasComparison) ...[
          const Text(
              'Check that this code is identical on both screens, then approve on BOTH devices:'),
          const SizedBox(height: 8),
          Text(r.sas,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('If the codes differ, tap Reject: someone may be intercepting.',
              style: TextStyle(fontSize: 12)),
        ] else
          const Text(
              'This device scanned your QR code. Approve to share your history with it.'),
      ]),
      actions: [
        TextButton(onPressed: r.reject, child: const Text('Reject')),
        FilledButton(
            onPressed: r.approve,
            child: Text(r.requiresSasComparison ? 'Codes match' : 'Approve')),
      ],
    );
  }
}
