import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Scans the pairing QR code and pops with its text.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final v = b.rawValue;
            if (v != null && v.contains('"smoogi"')) {
              _done = true;
              Navigator.of(context).pop(v);
              return;
            }
          }
        },
        errorBuilder: (context, error) => Center(
            child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
              'Camera unavailable (${error.errorCode.name}). Use the address or code option instead.'),
        )),
      ),
    );
  }
}
