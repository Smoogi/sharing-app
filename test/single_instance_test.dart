import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/services/desktop_shell.dart';

void main() {
  test('second instance asks the first to show and is told to exit', () async {
    final shown = Completer<void>();
    expect(await claimSingleInstance(() {
      if (!shown.isCompleted) shown.complete();
    }, port: 47791), isTrue);
    expect(await claimSingleInstance(() {}, port: 47791), isFalse);
    await shown.future.timeout(const Duration(seconds: 3));
  });
}
