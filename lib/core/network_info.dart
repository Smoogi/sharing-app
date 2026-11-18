import 'dart:io';

/// Local IPv4 addresses, most likely LAN address first.
Future<List<String>> localAddresses() async {
  try {
    final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    final addrs = <String>[];
    for (final i in ifs) {
      for (final a in i.addresses) {
        if (a.isLinkLocal) continue;
        addrs.add(a.address);
      }
    }
    int rank(String a) {
      if (a.startsWith('192.168.')) return 0;
      if (a.startsWith('10.')) return 1;
      if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a)) return 2;
      return 3;
    }

    addrs.sort((a, b) => rank(a).compareTo(rank(b)));
    return addrs;
  } catch (_) {
    return [];
  }
}
