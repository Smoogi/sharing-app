import 'protocol.dart';

/// Imageboard-style post numbers and quote links.
///
/// Every message has a stable 9-digit post number derived from its UUID, so
/// all devices show the same "No.123456789" without any coordination. A reply
/// is simply text containing `>>123456789`; because it lives in the message
/// body, replies sync, edit and search like any other text and need no
/// protocol change (older builds just show it as plain text).
int postNo(String messageId) {
  final hex = messageId.replaceAll('-', '');
  final n = int.tryParse(hex.substring(0, hex.length < 8 ? hex.length : 8),
          radix: 16) ??
      messageId.hashCode.abs();
  return 100000000 + n % 900000000;
}

String quoteOf(int no) => '>>$no';

final _refRe = RegExp(r'>>(\d{9})');
final _tokenRe = RegExp(r'>>(\d{9})|https?://[^\s<>"]+');

/// Post numbers quoted in [body], distinct, in order of appearance.
List<int> refsIn(String body) {
  final out = <int>[];
  for (final m in _refRe.allMatches(body)) {
    final n = int.parse(m.group(1)!);
    if (!out.contains(n)) out.add(n);
  }
  return out;
}

enum SpanKind { text, green, ref, url }

class BodySpan {
  const BodySpan(this.text, this.kind, {this.refNo});
  final String text;
  final SpanKind kind;
  final int? refNo;
}

/// Splits a post body into display spans: `>greentext` lines, `>>id` quote
/// links and URLs.
List<BodySpan> parseBody(String body) {
  final out = <BodySpan>[];
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final nl = i < lines.length - 1 ? '\n' : '';
    if (line.startsWith('>') && !line.startsWith('>>')) {
      out.add(BodySpan('$line$nl', SpanKind.green));
      continue;
    }
    var pos = 0;
    for (final m in _tokenRe.allMatches(line)) {
      if (m.start > pos) {
        out.add(BodySpan(line.substring(pos, m.start), SpanKind.text));
      }
      if (m.group(1) != null) {
        out.add(BodySpan(m.group(0)!, SpanKind.ref,
            refNo: int.parse(m.group(1)!)));
      } else {
        out.add(BodySpan(m.group(0)!, SpanKind.url));
      }
      pos = m.end;
    }
    if (pos < line.length) out.add(BodySpan(line.substring(pos), SpanKind.text));
    if (nl.isNotEmpty) out.add(BodySpan(nl, SpanKind.text));
  }
  return out;
}

/// Lookup tables over the full post list (never the filtered view, so
/// backlinks stay complete while searching).
class PostIndex {
  PostIndex(List<ChatMessage> posts) {
    for (final m in posts) {
      byNo.putIfAbsent(postNo(m.id), () => m); // oldest wins on collision
    }
    for (final m in posts) {
      if (m.kind != 'text') continue;
      final no = postNo(m.id);
      for (final r in refsIn(m.body)) {
        if (r == no || !byNo.containsKey(r)) continue;
        (outRefs[no] ??= <int>[]).add(r);
        (backlinks[r] ??= <int>[]).add(no);
      }
    }
  }

  final byNo = <int, ChatMessage>{};

  /// post -> posts it quotes (that exist)
  final outRefs = <int, List<int>>{};

  /// post -> posts that quote it
  final backlinks = <int, List<int>>{};

  /// All posts connected to [rootNo] through quote links in either direction
  /// (the "thread"), oldest first.
  List<ChatMessage> thread(int rootNo) {
    final seen = <int>{};
    final queue = <int>[rootNo];
    while (queue.isNotEmpty) {
      final n = queue.removeLast();
      if (!seen.add(n)) continue;
      queue.addAll(outRefs[n] ?? const []);
      queue.addAll(backlinks[n] ?? const []);
    }
    final list = [for (final n in seen) if (byNo[n] != null) byNo[n]!];
    list.sort((a, b) {
      final c = a.createdAt.compareTo(b.createdAt);
      return c != 0 ? c : a.originSeq.compareTo(b.originSeq);
    });
    return list;
  }

  /// Search: matches text, device name, or a post number (with or without
  /// `>>`; partial numbers of 3+ digits match).
  bool matches(ChatMessage m, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final numeric = q.replaceFirst('>>', '');
    if (RegExp(r'^\d{3,}$').hasMatch(numeric) &&
        postNo(m.id).toString().contains(numeric)) {
      return true;
    }
    return m.body.toLowerCase().contains(q) ||
        m.originName.toLowerCase().contains(q);
  }
}
