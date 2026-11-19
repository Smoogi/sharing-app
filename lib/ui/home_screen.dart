import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../app/app_controller.dart';
import '../core/posts.dart';
import '../services/clipboard_paste.dart';
import '../services/connection_manager.dart';
import 'devices_screen.dart';
import 'post_card.dart';
import 'thread_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _searchCtl = TextEditingController();
  bool _searching = false;
  bool _dragging = false;
  int? _highlight;
  Timer? _highlightTimer;
  final _subs = <StreamSubscription<dynamic>>[];
  int _lastCount = 0;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _lastCount = c.items.length;
    _subs.add(c.manager.pairingRequests.listen(_showPairing));
    _subs.add(c.manager.notices.listen((n) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(n)));
    }));
    c.addListener(_onChange);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      HardwareKeyboard.instance.addHandler(_onKey);
    }
  }

  bool _pasting = false;

  /// Ctrl+V / Cmd+V with an image (or copied files) on the clipboard sends it,
  /// like a screenshot taken with Win+Shift+S. Text pastes are left alone.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyV) return false;
    final kb = HardwareKeyboard.instance;
    final mod = Platform.isMacOS ? kb.isMetaPressed : kb.isControlPressed;
    if (!mod || kb.isAltPressed || !mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    unawaited(_pasteAttachments());
    return false; // never consume: ordinary text paste continues as usual
  }

  Future<void> _pasteAttachments() async {
    if (_pasting) return;
    _pasting = true;
    try {
      final tmp = Directory('${(await getTemporaryDirectory()).path}'
          '${Platform.pathSeparator}smoogi_paste');
      final paths = await clipboardAttachments(SystemClipboard(), tmp);
      if (paths.isEmpty) return;
      await _sendPaths(paths);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(paths.length == 1
                ? 'Pasted ${paths.first.split(Platform.pathSeparator).last}'
                : 'Pasted ${paths.length} files')));
      }
      for (final f in paths.where((f) => f.startsWith(tmp.path))) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
    } catch (_) {
      // Clipboard unreadable: behave like a normal paste.
    } finally {
      _pasting = false;
    }
  }

  bool get _atBottom {
    final p = _positions.itemPositions.value;
    if (p.isEmpty || c.items.isEmpty) return true;
    return p.any((e) => e.index >= c.items.length - 2);
  }

  void _onChange() {
    if (c.items.length > _lastCount && _atBottom) {
      final last = c.items.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.isAttached) _scroll.jumpTo(index: last);
      });
    }
    _lastCount = c.items.length;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    c.removeListener(_onChange);
    _highlightTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = c.composer.text;
    if (text.trim().isEmpty) return;
    try {
      await c.sendText(text);
      c.composer.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Android: ACTION_GET_CONTENT (Gallery, Photos, My Files, ...), like a
  /// browser. Files are copied to the app cache with their original names.
  Future<void> _attachAndroid() async {
    List<dynamic> picked;
    try {
      picked = await const MethodChannel('smoogi/files')
              .invokeMethod<List<dynamic>>('pickFiles') ??
          const [];
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open the picker: $e')));
      return;
    }
    final paths = [for (final f in picked) (f as Map)['path'] as String];
    if (paths.isEmpty) return;
    await _sendPaths(paths);
    // The copies in the cache are no longer needed once stored.
    for (final path in paths) {
      try {
        await File(path).parent.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _attach() async {
    if (Platform.isAndroid) return _attachAndroid();
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

  void _showPairing(PairingRequest req) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PairingDialog(request: req),
    );
  }

  void _jump(int no) {
    final i = c.items.indexWhere((m) => postNo(m.id) == no);
    if (i < 0) {
      // Hidden by the current search: show everything first.
      if (c.query.isNotEmpty) {
        _searchCtl.clear();
        c.search('');
        setState(() => _searching = false);
        WidgetsBinding.instance.addPostFrameCallback((_) => _jump(no));
      }
      return;
    }
    _scroll.scrollTo(
        index: i,
        duration: const Duration(milliseconds: 250),
        alignment: 0.1);
    setState(() => _highlight = no);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlight = null);
    });
  }

  void _thread(int no) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ThreadScreen(controller: c, rootNo: no)));
  }

  @override
  Widget build(BuildContext context) {
    final col = BoardColors.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final online = c.onlineIds.length;
        return Scaffold(
          backgroundColor: col.page,
          appBar: AppBar(
            title: _searching
                ? TextField(
                    controller: _searchCtl,
                    autofocus: true,
                    decoration: const InputDecoration(
                        hintText: 'Search text, name or No.123456789',
                        border: InputBorder.none),
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
                  isLabelVisible: online > 0 || c.updateInfo != null,
                  label: Text(c.updateInfo != null ? '!' : '$online'),
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
                              ? 'No posts yet.\nWrite one below, or pair a device from the Devices screen.'
                              : 'No matches.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: col.muted)),
                    )
                  : ScrollablePositionedList.builder(
                      itemScrollController: _scroll,
                      itemPositionsListener: _positions,
                      initialScrollIndex: c.items.length - 1,
                      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
                      itemCount: c.items.length,
                      itemBuilder: (_, i) {
                        final m = c.items[i];
                        return PostCard(
                          key: ValueKey(m.id),
                          message: m,
                          controller: c,
                          highlight: postNo(m.id) == _highlight,
                          onJump: _jump,
                          onThread: _thread,
                        );
                      },
                    ),
            ),
            _composer(col),
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
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                alignment: Alignment.center,
                child: const Text('Drop files to post',
                    style: TextStyle(fontSize: 24)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _composer(BoardColors col) {
    return Material(
      color: col.header,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            IconButton(
                tooltip: 'Attach files',
                onPressed: _attach,
                color: col.text,
                icon: const Icon(Icons.attach_file)),
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter, control: true):
                      _send,
                },
                child: TextField(
                  controller: c.composer,
                  focusNode: c.composerFocus,
                  minLines: 1,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(color: col.text),
                  decoration: InputDecoration(
                    hintText: 'Post (Ctrl+Enter sends). Tap a No. to reply.',
                    filled: true,
                    fillColor: col.page,
                    border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton(onPressed: _send, child: const Text('Post')),
          ]),
        ),
      ),
    );
  }
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
