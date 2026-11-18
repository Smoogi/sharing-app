import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_controller.dart';
import '../core/posts.dart';
import '../core/protocol.dart';
import '../data/attachment_store.dart';
import 'file_card.dart';

/// Yotsuba-style palette (light) and a dark board variant.
class BoardColors {
  const BoardColors({
    required this.page,
    required this.post,
    required this.header,
    required this.text,
    required this.name,
    required this.ref,
    required this.green,
    required this.backlink,
    required this.highlight,
    required this.muted,
  });

  final Color page, post, header, text, name, ref, green, backlink, highlight, muted;

  static const light = BoardColors(
    page: Color(0xFFEEF2FF),
    post: Color(0xFFD6DAF0),
    header: Color(0xFFB7C5D9),
    text: Color(0xFF000000),
    name: Color(0xFF117743),
    ref: Color(0xFFDD0000),
    green: Color(0xFF789922),
    backlink: Color(0xFF34345C),
    highlight: Color(0xFFF0C0B0),
    muted: Color(0xFF555577),
  );

  static const dark = BoardColors(
    page: Color(0xFF1D1F21),
    post: Color(0xFF282A2E),
    header: Color(0xFF373B41),
    text: Color(0xFFC5C8C6),
    name: Color(0xFF52A57B),
    ref: Color(0xFFCC6666),
    green: Color(0xFFB5BD68),
    backlink: Color(0xFF81A2BE),
    highlight: Color(0xFF5A4A44),
    muted: Color(0xFF969896),
  );

  static BoardColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

String boardDate(int createdAtMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${two(t.month)}/${two(t.day)}/${two(t.year % 100)}(${days[t.weekday - 1]})'
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// One post: header bar (name, date, No., menu), body, backlinks.
class PostCard extends StatefulWidget {
  const PostCard({
    super.key,
    required this.message,
    required this.controller,
    required this.onJump,
    this.onThread,
    this.onReply,
    this.highlight = false,
  });

  final ChatMessage message;
  final AppController controller;

  /// A quote link (or backlink) was tapped.
  final void Function(int no) onJump;

  /// "#" next to a link: show that post's thread. Null inside a thread view.
  final void Function(int no)? onThread;

  /// Called after a reply is queued in the composer (e.g. to leave a thread view).
  final VoidCallback? onReply;
  final bool highlight;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  bool _expanded = false;
  final _recognizers = <GestureRecognizer>[];
  static const _collapsedLines = 14;

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(VoidCallback f) {
    final r = TapGestureRecognizer()..onTap = f;
    _recognizers.add(r);
    return r;
  }

  void _snack(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  void _openRef(int no) {
    if (widget.controller.index.byNo.containsKey(no)) {
      widget.onJump(no);
    } else {
      _snack('No.$no is not in this history (not synced yet, or older).');
    }
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final c = widget.controller;
    final m = widget.message;
    final col = BoardColors.of(context);
    final mine = m.originDeviceId == c.identity.deviceId;
    final no = postNo(m.id);
    final backs = c.index.backlinks[no] ?? const <int>[];
    final status = mine ? c.syncStatus(m) : null;
    final base = TextStyle(color: col.text, fontSize: 15, height: 1.3);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: widget.highlight ? col.highlight : col.post,
        border: Border(
            left: BorderSide(
                color: widget.highlight ? col.ref : Colors.transparent,
                width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // --- header ---
        Container(
          color: col.header,
          padding: const EdgeInsets.fromLTRB(0, 2, 8, 2),
          child: Row(children: [
            _menu(context, m, no, col),
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: mine ? 'This device' : m.originName,
                      style: TextStyle(
                          color: col.name, fontWeight: FontWeight.bold)),
                  TextSpan(
                      text: '  ${boardDate(m.createdAt)}  ',
                      style: TextStyle(color: col.text)),
                  TextSpan(
                      text: 'No.$no',
                      style: TextStyle(
                          color: col.text, fontWeight: FontWeight.w600),
                      recognizer: _tap(() {
                        c.quotePost(no);
                        widget.onReply?.call();
                      })),
                ]),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ]),
        ),
        // --- body ---
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: m.kind == 'file'
              ? FileBody(message: m, controller: c)
              : m.kind != 'text'
                  ? Text('Unsupported item "${m.kind}" (update the app)',
                      style: base.copyWith(fontStyle: FontStyle.italic))
                  : _textBody(context, m, col, base),
        ),
        // --- footer: status + backlinks ---
        if (backs.isNotEmpty || status != null || m.editedAt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Wrap(
              spacing: 10,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final b in backs)
                  Text.rich(TextSpan(
                      style: TextStyle(color: col.backlink, fontSize: 12),
                      children: [
                        TextSpan(
                            text: '>>$b',
                            style: const TextStyle(
                                decoration: TextDecoration.underline),
                            recognizer: _tap(() => widget.onJump(b))),
                        if (widget.onThread != null)
                          TextSpan(
                              text: ' #',
                              recognizer: _tap(() => widget.onThread!(b))),
                      ])),
                if (m.editedAt != null)
                  Text('edited',
                      style: TextStyle(
                          color: col.muted,
                          fontSize: 11,
                          fontStyle: FontStyle.italic)),
                if (status != null)
                  Text(status, style: TextStyle(color: col.muted, fontSize: 11)),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _textBody(
      BuildContext context, ChatMessage m, BoardColors col, TextStyle base) {
    final c = widget.controller;
    final lines = '\n'.allMatches(m.body).length + 1;
    final long = lines > _collapsedLines && !_expanded;
    final body = long
        ? '${m.body.split('\n').take(_collapsedLines).join('\n')}\n'
        : m.body;
    final mono = lines > 3 ? 'monospace' : null;

    final spans = <InlineSpan>[];
    for (final s in parseBody(body)) {
      switch (s.kind) {
        case SpanKind.text:
          spans.add(TextSpan(text: s.text));
        case SpanKind.green:
          spans.add(TextSpan(text: s.text, style: TextStyle(color: col.green)));
        case SpanKind.ref:
          final no = s.refNo!;
          final you = c.index.byNo[no]?.originDeviceId == c.identity.deviceId;
          spans.add(TextSpan(
              text: s.text + (you ? ' (You)' : ''),
              style: TextStyle(
                  color: col.ref, decoration: TextDecoration.underline),
              recognizer: _tap(() => _openRef(no))));
          if (widget.onThread != null && c.index.byNo.containsKey(no)) {
            spans.add(TextSpan(
                text: ' #',
                style: TextStyle(color: col.backlink),
                recognizer: _tap(() => widget.onThread!(no))));
          }
        case SpanKind.url:
          spans.add(TextSpan(
              text: s.text,
              style: TextStyle(
                  color: col.backlink, decoration: TextDecoration.underline),
              recognizer: _tap(() => launchUrl(Uri.parse(s.text),
                  mode: LaunchMode.externalApplication))));
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText.rich(
        TextSpan(children: spans, style: base.copyWith(fontFamily: mono)),
      ),
      if (lines > _collapsedLines)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text(
                _expanded
                    ? 'Show less'
                    : 'Comment too long ($lines lines). Click here to view the full text.',
                style: TextStyle(color: col.backlink, fontSize: 12)),
          ),
        ),
    ]);
  }

  Widget _menu(BuildContext context, ChatMessage m, int no, BoardColors col) {
    final c = widget.controller;
    return PopupMenuButton<String>(
      tooltip: 'Post menu',
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert, size: 18, color: col.text),
      onSelected: (v) async {
        switch (v) {
          case 'reply':
            c.quotePost(no);
            widget.onReply?.call();
          case 'edit':
            await _edit(context);
          case 'copy':
            await Clipboard.setData(ClipboardData(
                text: m.kind == 'file'
                    ? (FileMeta.tryParse(m.body)?.name ?? m.body)
                    : m.body));
            if (mounted) _snack('Copied');
          case 'copyno':
            await Clipboard.setData(ClipboardData(text: quoteOf(no)));
            if (mounted) _snack('Copied ${quoteOf(no)}');
          case 'thread':
            widget.onThread?.call(no);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'reply', child: Text('Reply')),
        if (m.kind == 'text')
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
        const PopupMenuItem(value: 'copy', child: Text('Copy text')),
        const PopupMenuItem(value: 'copyno', child: Text('Copy post link')),
        if (widget.onThread != null)
          const PopupMenuItem(value: 'thread', child: Text('Show thread')),
      ],
    );
  }

  Future<void> _edit(BuildContext context) async {
    final ctl = TextEditingController(text: widget.message.body);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit post'),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: ctl,
            autofocus: true,
            minLines: 3,
            maxLines: 14,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (text == null || text == widget.message.body) return;
    try {
      await widget.controller.editMessage(widget.message, text);
    } catch (e) {
      if (mounted) _snack('$e');
    }
  }
}
