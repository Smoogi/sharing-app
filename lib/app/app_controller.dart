import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../core/identity.dart';
import '../core/network_info.dart';
import '../core/posts.dart';
import '../core/platform_vault.dart';
import '../core/settings.dart';
import '../services/self_update.dart';
import '../services/update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
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

  /// Update check state. [updateInfo] is non-null while a newer release exists.
  UpdateService updates = UpdateService();
  String? currentVersion;
  UpdateInfo? updateInfo;
  bool checkingUpdate = false;
  String? updateError;
  bool updateCheckedOk = false;
  double? installProgress; // non-null while downloading an update

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
      ..add(transfers.changes.listen((_) => _scheduleRefresh()));
    WidgetsBinding.instance.addObserver(this);
    ready = true;
    await refresh();
    if (network) unawaited(ShareReceiver.start(_onShare));
    if (network) {
      unawaited(_version().then((_) => notifyListeners(), onError: (_) {}));
      unawaited(_startupUpdateCheck());
    }
  }

  Future<String> _version() async =>
      currentVersion ??= (await PackageInfo.fromPlatform()).version;

  /// Daily check, only when the user switched it on.
  Future<void> _startupUpdateCheck() async {
    if (!settings.autoUpdateCheck) return;
    final day = const Duration(hours: 24).inMilliseconds;
    if (DateTime.now().millisecondsSinceEpoch - settings.lastUpdateCheck < day) return;
    await checkForUpdates();
  }

  /// Asks GitHub for the latest release. Never downloads or installs anything.
  Future<void> checkForUpdates() async {
    if (checkingUpdate) return;
    checkingUpdate = true;
    updateError = null;
    updateCheckedOk = false;
    notifyListeners();
    try {
      updateInfo = await updates.check(await _version());
      updateCheckedOk = true;
      settings.lastUpdateCheck = DateTime.now().millisecondsSinceEpoch;
      await settings.save();
    } catch (e) {
      updateError = 'Could not check for updates: $e';
    } finally {
      checkingUpdate = false;
      notifyListeners();
    }
  }

  /// Downloads the update for this platform, verifies it, installs it and
  /// quits so the new version can take over. Windows and macOS only.
  Future<void> installUpdate() async {
    final info = updateInfo, name = SelfUpdate.assetName;
    if (info == null || name == null || installProgress != null) return;
    installProgress = 0;
    updateError = null;
    notifyListeners();
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'smoogi_update_${info.version}'));
      final file = await updates.download(info, name, dir, onProgress: (f) {
        installProgress = f;
        notifyListeners();
      });
      await SelfUpdate.launch(file);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(0);
    } catch (e) {
      updateError = 'Update failed: $e';
      installProgress = null;
      notifyListeners();
    }
  }

  Future<void> setAutoUpdateCheck(bool on) async {
    settings.autoUpdateCheck = on;
    await settings.save();
    notifyListeners();
    if (on) unawaited(_startupUpdateCheck());
  }

  Timer? _refreshTimer;

  /// Transfers report progress for every chunk; reloading the whole list that
  /// often would swamp the UI, so progress updates are coalesced.
  void _scheduleRefresh() {
    if (_refreshTimer?.isActive ?? false) return;
    _refreshTimer = Timer(const Duration(milliseconds: 400), () => refresh());
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
    if (Platform.isAndroid) {
      final meta = FileMeta.tryParse(m.body);
      if (a == null || meta == null) return null;
      return const MethodChannel('smoogi/files').invokeMethod<String>(
          'saveToDownloads',
          {'path': a.path, 'name': meta.name, 'mime': meta.mime});
    }
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
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    _discovery?.stop();
    manager.stop();
    super.dispose();
  }
}
