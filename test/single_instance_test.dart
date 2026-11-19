import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/services/desktop_shell.dart';

void main() {
  test('second instance asks the first to show and is told to exit', () async {
    final shown = Completer<void>();
    expect(await claimSingleInstance(() {
      if (!shown.isCompleted) shown.complete();
    }), isTrue);
    expect(await claimSingleInstance(() {}), isFalse);
    await shown.future.timeout(const Duration(seconds: 3));
  });
}
