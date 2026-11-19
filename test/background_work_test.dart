import 'package:flutter_test/flutter_test.dart';
import 'package:smoogi_share/services/background_work.dart';

void main() {
  test('unacked posts only count for connected peers', () {
    final local = {'me': 5, 'poco': 2};
    expect(hasUnackedForOnline(local, {'win': {'me': 5, 'poco': 2}}, {'win'}), isFalse);
    expect(hasUnackedForOnline(local, {'win': {'me': 4, 'poco': 2}}, {'win'}), isTrue);
    // a peer we know nothing about yet needs everything
    expect(hasUnackedForOnline(local, {}, {'mac'}), isTrue);
    // offline peers never keep the service alive
    expect(hasUnackedForOnline(local, {'win': {'me': 1}}, <String>{}), isFalse);
    expect(hasUnackedForOnline({}, {}, {'mac'}), isFalse);
  });
}
