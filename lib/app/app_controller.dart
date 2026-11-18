import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../core/identity.dart';
import '../core/network_info.dart';
import '../core/posts.dart';
import '../core/platform_vault.dart';
import '../core/settings.dart';
import '../core/protocol.dart';
import '../data/app_database.dart';
import '../data/attachment_store.dart';
import '../data/message_repository.dart';
import '../data/peer_repository.dart';
import '../services/connection_manager.dart';
import '../services/pairing_service.dart';
import '../services/share_receiver.dart';
import '../services/transfer_service.dart';
import '../transport/discovery.dart';
import '../transport/secure_tcp_transport.dart';

/// Glue between services and widgets. Widgets never touch sockets or SQL.
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  late final DeviceIdentity identity;
  late final FileIdentityStore _identityStore;
  late final MessageRepository messages;
  late final PeerRepository peers;
  late final PairingService pairing;
  late final ConnectionManager manager;
  late final SecureTcpTransport _transport;
  late final AttachmentStore store;
  late final TransferService transfers;
  late final AppSettings settings;
  final _autoTried = <String>{};
  bool _autoRunning = false;
  DiscoveryService? _discovery;
  Map<String, LocalAttachment> attachments = {};

  /// Posts shown in the main list (search applied).
  List<ChatMessage> items = [];

  /// Every post, unfiltered, plus quote/backlink lookups.
  List<ChatMessage> allPosts = [];
  PostIndex index = PostIndex(const []);

  /// Post numbers of deleted posts (so quotes can say "(Deleted)").
  Set<int> deletedNos = {};

  final composer = TextEditingController();
  final composerFocus = FocusNode();
  List<Peer> pairedPeers = [];
  Map<String, Map<String, int>> peerVectors = {};
  List<String> addresses = [];
  String query = '';
  bool ready = false;
  final _subs = <StreamSubscription<dynamic>>[];

  int get port => _transport.port;
  Set<String> get onlineIds => manager.onlinePeerIds;

  /// [dataDir], [port], [network] exist so tests can run without plugins/ports.
  Future<void> init({Directory? dataDir, int port = 48620, bool network = true}) async {
    final dir = dataDir ?? await getApplicationSupportDirectory();
    _identityStore = FileIdentityStore(File(p.join(dir.path, 'identity.json')),
        vault: PlatformVault.create(dir));
    final os = Platform.isAndroid ? 'Android' : Platform.operatingSystem;
    identity = await _identityStore.loadOrCreate(defaultName: os);
    // First run: make the default name recognisable.
    if (identity.name == os) {
      identity.name = '$os ${identity.deviceId.substring(0, 4)}';
      await _identityStore.save(identity);
    }
    settings = await AppSettings.load(File(p.join(dir.path, 'settings.json')));
    final db = await AppDatabase.open(p.join(dir.path, 'smoogi.db'));
    messages = MessageRepository(db, localDeviceId: identity.deviceId);
    peers = PeerRepository(db);
    pairing = PairingService();
    _transport = SecureTcpTransport(identity: identity, platform: os, preferredPort: port);
    manager = ConnectionManager(
      identity: identity,
      transport: _transport,
      peers: peers,
      messages: messages,
      pairing: pairing,
    );
    store = AttachmentStore(Directory(p.join(dir.path, 'attachments')), db);
    transfers = TransferService(manager: manager, store: store, messages: messages);
    await manager.start();
    _discovery = DiscoveryService(
      deviceId: identity.deviceId,
      portProvider: () => _transport.port,
      onSeen: manager.onDiscovered,
    );
    if (network) unawaited(_discovery!.start());
    addresses = await localAddresses();

    _subs
      ..add(messages.changes.listen((_) => refresh()))
      ..add(peers.changes.listen((_) => refresh()))
      ..add(manager.stateChanges.listen((_) {
        _autoTried.clear(); // a (re)connection is a fresh chance to download
        refresh();
      }))
      ..add(transfers.changes.listen((_) => refresh()));
    WidgetsBinding.instance.addObserver(this);
    ready = true;
    await refresh();
    if (network) unawaited(ShareReceiver.start(_onShare));
  }

  Future<void> refresh() async {
    allPosts = await messages.recent(limit: 5000);
    index = PostIndex(allPosts);
    items = query.trim().isEmpty
        ? allPosts
        : [for (final m in allPosts) if (index.matches(m, query)) m];
    pairedPeers = await peers.all();
    peerVectors = await peers.vectors();
    attachments = await store.all();
    final deleted = await messages.deletedIds();
    deletedNos = {for (final id in deleted) postNo(id)};
    // Drop files of posts deleted on any device.
    for (final id in attachments.keys.where(deleted.contains).toList()) {
      await store.remove(id);
      attachments.remove(id);
    }
    notifyListeners();
    unawaited(_autoDownload());
  }

  Future<void> reloadAddresses() async {
    addresses = await localAddresses();
    notifyListeners();
  }

  Future<void> search(String q) async {
    query = q;
    await refresh();
  }

  /// Imageboard-style reply: put ">>No." at the start of the draft.
  void quotePost(int no) {
    final q = quoteOf(no);
    final t = composer.text;
    if (!t.contains(q)) {
      composer.text = t.isEmpty ? '$q\n' : '$q\n$t';
    }
    composer.selection = TextSelection.collapsed(offset: composer.text.length);
    composerFocus.requestFocus();
    notifyListeners();
  }

  Future<void> sendText(String text) async {
    await manager.sendText(text);
  }

  Future<void> setAutoDownloadMb(int mb) async {
    settings.autoDownloadMaxMb = mb;
    await settings.save();
    _autoTried.clear();
    notifyListeners();
    unawaited(_autoDownload());
  }

  /// Downloads small files from connected devices, one at a time.
  Future<void> _autoDownload() async {
    final limit = settings.autoDownloadMaxMb * 1024 * 1024;
    if (_autoRunning || limit <= 0 || onlineIds.isEmpty) return;
    _autoRunning = true;
    try {
      for (final m in List<ChatMessage>.of(items)) {
        if (m.kind != 'file' ||
            attachments.containsKey(m.id) ||
            _autoTried.contains(m.id) ||
            transfers.isActive(m.id)) {
          continue;
        }
        final meta = FileMeta.tryParse(m.body);
        if (meta == null || meta.size > limit) continue;
        if (onlineIds.isEmpty) break;
        _autoTried.add(m.id);
        await transfers.download(m);
      }
    } finally {
      _autoRunning = false;
    }
  }

  Future<void> deleteMessage(ChatMessage m) async {
    await manager.sendDelete(m.id);
    await store.remove(m.id);
  }

  Future<void> editMessage(ChatMessage m, String newText) async {
    await manager.sendEdit(m.id, newText);
  }

  Future<void> sendFiles(List<String> paths) async {
    for (final path in paths) {
      await transfers.sendFile(File(path));
    }
  }

  Future<void> _onShare(SharedContent c) async {
    final text = (c.text ?? '').trim().isNotEmpty ? c.text! : (c.subject ?? '');
    if (text.trim().isNotEmpty) await sendText(text);
    for (final f in c.files) {
      try {
        await transfers.sendFile(File(f.path), name: f.name);
      } finally {
        try {
          await File(f.path).delete(); // drop the cache copy
        } catch (_) {}
      }
    }
  }

  Future<void> download(ChatMessage m) => transfers.download(m);

  Future<void> openFile(ChatMessage m) async {
    final a = attachments[m.id];
    if (a != null) await OpenFilex.open(a.path);
  }

  /// Desktop: copy into the user's Downloads folder (never overwrites).
  Future<String?> saveToDownloads(ChatMessage m) async {
    final a = attachments[m.id];
    final dir = await getDownloadsDirectory();
    if (a == null || dir == null) return null;
    return store.saveCopy(a, dir);
  }

  Future<void> pairWithCode(String text) async {
    await manager.pairWithQr(await PairingQrPayload.decode(text.trim()));
  }

  Future<void> rename(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    identity.name = n.length > 64 ? n.substring(0, 64) : n;
    await _identityStore.save(identity);
    notifyListeners();
  }

  /// Delivery state of one of our own messages across paired devices.
  String syncStatus(ChatMessage m) {
    if (pairedPeers.isEmpty) return 'Local only';
    var acked = 0;
    for (final peer in pairedPeers) {
      if ((peerVectors[peer.deviceId]?[m.originDeviceId] ?? 0) >= m.originSeq) {
        acked++;
      }
    }
    return acked == pairedPeers.length
        ? 'Synced'
        : 'Pending $acked/${pairedPeers.length}';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      reloadAddresses();
      manager.reconnectNow();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    _discovery?.stop();
    manager.stop();
    super.dispose();
  }
}
