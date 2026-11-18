import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_controller.dart';
import '../services/pairing_service.dart';
import '../services/self_update.dart';
import '../services/update_service.dart';
import 'scan_screen.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '48620');
  late final String _qrData;
  bool _busy = false;
  String? _error;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    // Unknown devices are only accepted while this screen is open.
    c.pairing.setAccepting(true);
    final payload = PairingQrPayload(
      deviceId: c.identity.deviceId,
      publicKey: c.identity.publicKey,
      name: c.identity.name,
      addresses: c.addresses,
      port: c.port,
      token: c.pairing.newToken(),
    );
    _qrData = payload.encode();
    c.reloadAddresses();
  }

  @override
  void dispose() {
    c.pairing.setAccepting(false);
    _code.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  final _code = TextEditingController();

  bool get _canScan => Platform.isAndroid || Platform.isMacOS || Platform.isIOS;

  Future<void> _scan() async {
    final text = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (text != null) await _pairWithCode(text);
  }

  Future<void> _pairWithCode(String text) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await c.pairWithCode(text);
    } catch (e) {
      setState(() => _error = 'Could not pair: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pair() async {
    final port = int.tryParse(_port.text.trim());
    if (_host.text.trim().isEmpty || port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Enter a valid address and port');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await c.manager.pairWithAddress(_host.text.trim(), port);
    } catch (e) {
      setState(() => _error = 'Could not connect: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final addr = c.addresses.isEmpty ? ['(no network)'] : c.addresses;
        return Scaffold(
          appBar: AppBar(title: const Text('Devices')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text('This device', style: Theme.of(context).textTheme.titleMedium),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(c.identity.name),
              subtitle: Text('ID ${c.identity.fingerprint}'),
              trailing: IconButton(
                  icon: const Icon(Icons.edit), onPressed: _rename),
            ),
            for (final a in addr)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: SelectableText('$a:${c.port}'),
                trailing: IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: '$a:${c.port}'))),
              ),
            const SizedBox(height: 8),
            Text('Pair a new device',
                style: Theme.of(context).textTheme.titleMedium),
            const Text(
                'Keep this screen open on the device being paired. On the other device, scan this code, paste the pairing code, or enter the address above.'),
            const SizedBox(height: 12),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(data: _qrData, size: 200),
              ),
            ),
            Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
              TextButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: _qrData)),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy pairing code')),
              if (_canScan)
                FilledButton.icon(
                    onPressed: _busy ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan other device')),
            ]),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  decoration: const InputDecoration(
                      labelText: 'Paste pairing code from other device'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: _busy ? null : () => _pairWithCode(_code.text),
                  child: const Text('Pair')),
            ]),
            const SizedBox(height: 16),
            Text('Pair by address',
                style: Theme.of(context).textTheme.titleSmall),
            Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(labelText: 'IP address'),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _port,
                  decoration: const InputDecoration(labelText: 'Port'),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: _busy ? null : _pair, child: const Text('Pair')),
            ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const Divider(height: 32),
            Text('Files', style: Theme.of(context).textTheme.titleMedium),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-download files up to'),
              trailing: DropdownButton<int>(
                value: const [0, 5, 10, 25, 100]
                        .contains(c.settings.autoDownloadMaxMb)
                    ? c.settings.autoDownloadMaxMb
                    : 10,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Off')),
                  DropdownMenuItem(value: 5, child: Text('5 MB')),
                  DropdownMenuItem(value: 10, child: Text('10 MB')),
                  DropdownMenuItem(value: 25, child: Text('25 MB')),
                  DropdownMenuItem(value: 100, child: Text('100 MB')),
                ],
                onChanged: (v) => c.setAutoDownloadMb(v ?? 0),
              ),
            ),
            const Divider(height: 32),
            Text('Updates', style: Theme.of(context).textTheme.titleMedium),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Version ${c.currentVersion ?? '-'}'),
              subtitle: Text(c.checkingUpdate
                  ? 'Checking...'
                  : c.updateInfo != null
                      ? 'Version ${c.updateInfo!.version} is available'
                      : c.updateError ??
                          (c.updateCheckedOk
                              ? 'You are up to date'
                              : 'Checks GitHub only when you ask')),
              trailing: OutlinedButton(
                  onPressed: c.checkingUpdate ? null : _checkUpdates,
                  child: const Text('Check for updates')),
            ),
            if (c.installProgress != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Downloading update. The app restarts when it is ready.'),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: c.installProgress),
                ]),
              ),
            if (c.updateInfo != null && c.installProgress == null)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                    onPressed: () => _showUpdate(c.updateInfo!),
                    icon: const Icon(Icons.system_update),
                    label: Text('See version ${c.updateInfo!.version}')),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Check once a day automatically'),
              subtitle: const Text(
                  'Off by default. Only asks GitHub for the newest version; nothing is installed for you.'),
              value: c.settings.autoUpdateCheck,
              onChanged: c.setAutoUpdateCheck,
            ),
            const Divider(height: 32),
            Text('Paired devices',
                style: Theme.of(context).textTheme.titleMedium),
            if (c.pairedPeers.isEmpty) const Text('None yet.'),
            for (final p in c.pairedPeers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.circle,
                    size: 14,
                    color: c.onlineIds.contains(p.deviceId)
                        ? Colors.green
                        : Colors.grey),
                title: Text(p.name),
                subtitle: Text(
                    '${p.platform} · ${c.onlineIds.contains(p.deviceId) ? 'Connected' : 'Offline'}'
                    '${p.lastHost != null ? ' · last ${p.lastHost}' : ''}'),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmRemove(p.deviceId, p.name),
                ),
              ),
          ]),
        );
      },
    );
  }

  Future<void> _checkUpdates() async {
    await c.checkForUpdates();
    if (mounted && c.updateInfo != null) await _showUpdate(c.updateInfo!);
  }

  Future<void> _showUpdate(UpdateInfo u) async {
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Version ${u.version} is available'),
        content: SingleChildScrollView(
            child: SelectableText(u.notes.isEmpty ? 'No release notes.' : u.notes)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(SelfUpdate.supported
                  ? 'Download and install'
                  : 'Open download page')),
        ],
      ),
    );
    if (open == true && SelfUpdate.supported) {
      await c.installUpdate();
    } else if (open == true) {
      await launchUrl(Uri.parse(u.url), mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _rename() async {
    final ctl = TextEditingController(text: c.identity.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (name != null) await c.rename(name);
  }

  Future<void> _confirmRemove(String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text(
            'It will stop syncing with this device. Messages already received stay. Remove it on the other device too.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await c.manager.removePeer(id);
  }
}
