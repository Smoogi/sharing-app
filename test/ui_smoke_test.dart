import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/app/app_controller.dart';
import 'package:smoogi_share/core/posts.dart';
import 'package:smoogi_share/ui/home_screen.dart';
import 'package:smoogi_share/ui/post_card.dart';
import 'package:smoogi_share/ui/thread_screen.dart';

void main() {
  test('board date is dd/mm/yyyy', () {
    final ms = DateTime(2026, 11, 18, 1, 25, 32).toUtc().millisecondsSinceEpoch;
    expect(boardDate(ms), '18/11/2026(Wed)01:25:32');
  });

  testWidgets('imageboard UI: posts, quote links, backlinks, thread, reply',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppController c;
    late int rootNo, replyNo;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('smoogi_ui');
      c = AppController();
      await c.init(dataDir: dir, port: 0, network: false);
      final root = await c.manager.sendText('First post\n>greentext line\nhttps://example.org');
      rootNo = postNo(root.id);
      final reply = await c.manager.sendText('>>$rootNo this is a reply');
      replyNo = postNo(reply.id);
      await c.manager.sendText('x\n' * 30 + 'very long post');
      await c.refresh();
    });

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: HomeScreen(controller: c),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    // Post numbers are shown for every post.
    expect(find.textContaining('No.$rootNo', findRichText: true), findsWidgets);
    expect(find.textContaining('No.$replyNo', findRichText: true), findsWidgets);
    // Backlink row under the root post points at the reply.
    expect(find.textContaining('>>$replyNo', findRichText: true), findsWidgets);
    // Collapsed long post offers expansion.
    expect(find.textContaining('Comment too long', findRichText: true), findsOneWidget);

    // Search by post number narrows the list.
    await tester.runAsync(() => c.search('>>$replyNo'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.items.map((m) => postNo(m.id)), contains(replyNo));
    await tester.runAsync(() => c.search(''));
    await tester.pump(const Duration(milliseconds: 200));

    // Reply via the controller puts the quote in the composer.
    c.quotePost(rootNo);
    expect(c.composer.text, '>>$rootNo\n');
    c.quotePost(rootNo); // idempotent
    expect(c.composer.text, '>>$rootNo\n');

    // Thread screen renders root + reply.
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: ThreadScreen(controller: c, rootNo: rootNo),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Thread of No.$rootNo', findRichText: true), findsOneWidget);
    expect(find.byType(PostCard), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  test('deleting a file post removes it and its stored file', () async {
    final dir = await Directory.systemTemp.createTemp('smoogi_del');
    final c = AppController();
    await c.init(dataDir: dir, port: 0, network: false);
    final src = File('${dir.path}/pic.bin')..writeAsBytesSync(List.filled(1000, 7));
    await c.sendFiles([src.path]);
    final text = await c.manager.sendText('hello');
    await c.refresh();
    expect(c.items.length, 2);
    final file = c.items.firstWhere((m) => m.kind == 'file');
    final stored = c.attachments[file.id]!.path;
    expect(File(stored).existsSync(), isTrue);

    await c.deleteMessage(file);
    await c.deleteMessage(text);
    await c.refresh();
    expect(c.items, isEmpty);
    expect(File(stored).existsSync(), isFalse);
    expect(c.deletedNos, containsAll([postNo(file.id), postNo(text.id)]));
  });
}
