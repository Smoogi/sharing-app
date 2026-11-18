import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/core/posts.dart';
import 'package:smoogi_share/core/protocol.dart';

final dev = 'a' * 32;
ChatMessage msg(String id, int seq, String body, {String kind = 'text'}) =>
    ChatMessage(
        id: id,
        originDeviceId: dev,
        originName: 'Poco',
        originSeq: seq,
        createdAt: 1000 + seq,
        kind: kind,
        body: body);

void main() {
  test('post numbers are 9 digits, stable and equal on every device', () {
    const id = '3f2b8c1e-aaaa-4bbb-8ccc-123456789abc';
    expect(postNo(id), postNo(id));
    expect(postNo(id).toString().length, 9);
    expect(postNo('00000000-0000-4000-8000-000000000000'), 100000000);
  });

  test('refsIn finds distinct quotes in order', () {
    expect(refsIn('>>123456789 hi >>987654321 and >>123456789 again'),
        [123456789, 987654321]);
    expect(refsIn('>>12345 short and no refs'), isEmpty);
  });

  test('parseBody: greentext, quote links, urls, plain', () {
    final s = parseBody('>>123456789\n>be me\nsee https://x.org/a?b=1 ok');
    expect(s.map((e) => e.kind).toList(), [
      SpanKind.ref,
      SpanKind.text, // newline
      SpanKind.green,
      SpanKind.text,
      SpanKind.url,
      SpanKind.text,
    ]);
    expect(s.first.refNo, 123456789);
    expect(s.where((e) => e.kind == SpanKind.green).single.text, '>be me\n');
    expect(s.map((e) => e.text).join(), '>>123456789\n>be me\nsee https://x.org/a?b=1 ok');
  });

  test('index: backlinks, threads, and search by id', () {
    final a = msg('00000001-0000-4000-8000-000000000000', 1, 'root post');
    final b = msg('00000002-0000-4000-8000-000000000000', 2,
        '${quoteOf(postNo(a.id))} reply to root');
    final c = msg('00000003-0000-4000-8000-000000000000', 3,
        '${quoteOf(postNo(b.id))} reply to reply');
    final d = msg('00000004-0000-4000-8000-000000000000', 4, 'unrelated');
    final idx = PostIndex([a, b, c, d]);

    expect(idx.backlinks[postNo(a.id)], [postNo(b.id)]);
    expect(idx.backlinks[postNo(b.id)], [postNo(c.id)]);
    expect(idx.thread(postNo(a.id)).map((m) => m.id), [a.id, b.id, c.id]);
    expect(idx.thread(postNo(c.id)).map((m) => m.id), [a.id, b.id, c.id]);
    expect(idx.thread(postNo(d.id)).map((m) => m.id), [d.id]);

    expect(idx.matches(d, '${postNo(a.id)}'), isFalse);
    expect(idx.matches(a, '>>${postNo(a.id)}'), isTrue);
    expect(idx.matches(d, 'UNRELATED'), isTrue);
    expect(idx.matches(d, postNo(d.id).toString().substring(2, 7)), isTrue);
  });

  test('quotes of unknown posts and self quotes create no links', () {
    final a = msg('00000001-0000-4000-8000-000000000000', 1,
        '>>999999999 ${quoteOf(100000000)}');
    final idx = PostIndex([a]);
    expect(idx.backlinks, isEmpty);
    expect(idx.outRefs, isEmpty);
  });
}
