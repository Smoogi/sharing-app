import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../app/app_controller.dart';
import '../core/posts.dart';
import 'post_card.dart';

/// Shows a post together with everything connected to it by quote links.
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({super.key, required this.controller, required this.rootNo});
  final AppController controller;
  final int rootNo;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final _scroll = ItemScrollController();
  int? _highlight;

  @override
  Widget build(BuildContext context) {
    final col = BoardColors.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final posts = widget.controller.index.thread(widget.rootNo);
        return Scaffold(
          backgroundColor: col.page,
          appBar: AppBar(
              title: Text('Thread of No.${widget.rootNo}  (${posts.length})')),
          body: posts.isEmpty
              ? const Center(child: Text('Post not found'))
              : ScrollablePositionedList.builder(
                  itemScrollController: _scroll,
                  padding: const EdgeInsets.all(8),
                  itemCount: posts.length,
                  itemBuilder: (_, i) {
                    final m = posts[i];
                    return PostCard(
                      key: ValueKey(m.id),
                      message: m,
                      controller: widget.controller,
                      highlight: postNo(m.id) == _highlight ||
                          postNo(m.id) == widget.rootNo,
                      onJump: (no) {
                        final idx = posts.indexWhere((p) => postNo(p.id) == no);
                        if (idx >= 0) {
                          _scroll.scrollTo(
                              index: idx,
                              duration: const Duration(milliseconds: 250));
                          setState(() => _highlight = no);
                        }
                      },
                      onReply: () => Navigator.of(context).pop(), // composer is on the main screen
                    );
                  },
                ),
        );
      },
    );
  }
}
