import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/core/protocol.dart';

void main() {
  const dev = '0123456789abcdef0123456789abcdef';
  ChatMessage sample() => const ChatMessage(
      id: 'id-1',
      originDeviceId: dev,
      originName: 'Poco',
      originSeq: 3,
      createdAt: 1700000000000,
      kind: 'text',
      body: 'line1\nline2 "quoted" é\u{1F600}\ttab');

  test('message JSON round-trips exactly, preserving multiline/unicode', () {
    final m = sample();
    final back = ChatMessage.fromJson(jsonDecode(jsonEncode(m.toJson())));
    expect(back, m);
    expect(back.body, m.body);
  });

  test('rejects malformed messages', () {
    final good = sample().toJson();
    for (final bad in <Map<String, dynamic>>[
      {...good, 'id': ''},
      {...good, 'od': 'nothex'},
      {...good, 'seq': 0},
      {...good, 'seq': '1'},
      {...good, 'ts': -1},
      {...good, 'b': 5},
      {...good, 'k': ''},
    ]) {
      expect(() => ChatMessage.fromJson(bad), throwsA(isA<ProtocolException>()));
    }
    expect(() => ChatMessage.fromJson('x'), throwsA(isA<ProtocolException>()));
  });

  test('vector parsing validates', () {
    expect(parseVector({dev: 4}), {dev: 4});
    expect(() => parseVector({'bad': 1}), throwsA(isA<ProtocolException>()));
    expect(() => parseVector({dev: -1}), throwsA(isA<ProtocolException>()));
  });
}
