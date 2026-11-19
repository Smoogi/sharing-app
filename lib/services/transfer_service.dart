import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/protocol.dart';
import '../data/attachment_store.dart';
import '../data/message_repository.dart';
import '../transport/peer_channel.dart';
import 'connection_manager.dart';

enum TransferStatus { downloading, interrupted, failed, unavailable }

class TransferState {
  TransferState(this.status, this.total, {this.received = 0, this.message});
  TransferStatus status;
  int received;
  final int total;
  String? message;
  double get fraction => total == 0 ? 0 : received / total;
}

enum _Outcome { ok, notFound, interrupted, badHash }

class _Download {
  _Download(this.messageId, this.meta);
  final String messageId;
  final FileMeta meta;
  PeerChannel? channel;
  RandomAccessFile? raf;
  int received = 0;
  Completer<_Outcome>? result;
  Timer? watchdog;

  /// Serialises file writes: RandomAccessFile.close() throws while an
  /// async write is pending.
  Future<void> writeChain = Future.value();
}

/// File transfer on top of the sync channel. Metadata syncs automatically as
/// a 'file' message; bytes move only on request, streamed in chunks with
/// resume support and SHA-256 verification.
///
///   file_get   {mid, offset}              downloader -> source
///   file_start {mid, offset}              source -> downloader
///   file_chunk {mid, off, bin(raw)}       source -> downloader (binary frame)
///   file_end   {mid}
///   file_err   {mid, reason}              e.g. not_found
class TransferService {
  TransferService({
    required this.manager,
    required this.store,
    required this.messages,
    this.chunkSize = 192 * 1024,
    this.stallTimeout = const Duration(seconds: 20),
  }) {
    manager.transfers = this;
  }

  final ConnectionManager manager;
  final AttachmentStore store;
  final MessageRepository messages;
  final int chunkSize;
  final Duration stallTimeout;

  final states = <String, TransferState>{};
  final _downloads = <String, _Download>{};
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  void _set(String mid, TransferState s) {
    states[mid] = s;
    _changes.add(null);
  }

  // --- sending ---------------------------------------------------------------

  /// Imports [src] into app storage and creates the shared message.
  Future<ChatMessage> sendFile(File src, {String? name}) async {
    final staged = await store.stage(src, name: name);
    final msg = await messages.createLocalText(
        staged.meta.toBody(), manager.identity.name,
        kind: 'file');
    await store.commitStaged(msg.id, staged.staged, staged.meta);
    await manager.broadcastMessages([msg]);
    return msg;
  }

  // --- downloading -------------------------------------------------------------

  bool isActive(String mid) => _downloads.containsKey(mid);

  int _serving = 0;

  /// True while any file is being downloaded or served to a peer.
  bool get hasActive => _downloads.isNotEmpty || _serving > 0;


  /// Download the file of [m]; resumes a partial file if present. Tries the
  /// origin device first, then any other connected device that has it.
  Future<void> download(ChatMessage m) async {
    final meta = FileMeta.tryParse(m.body);
    if (meta == null || m.kind != 'file') return;
    if (await store.get(m.id) != null || _downloads.containsKey(m.id)) return;

    final d = _Download(m.id, meta);
    _downloads[m.id] = d;
    try {
      final candidates = manager.onlinePeerIds.toList()
        ..sort((a, b) => (b == m.originDeviceId ? 1 : 0) -
            (a == m.originDeviceId ? 1 : 0));
      if (candidates.isEmpty) {
        _set(m.id,
            TransferState(TransferStatus.unavailable, meta.size,
                message: 'No device that has this file is online'));
        return;
      }
      final part = store.partFileFor(m.id, meta);
      await store.dirFor(m.id).create(recursive: true);
      var anyInterrupted = false;
      var anyBad = false;
      for (final id in candidates) {
        // A dropped connection may simply have been replaced by a newer one to
        // the same device (simultaneous dials): resume on it right away.
        for (var attempt = 0; attempt < 4; attempt++) {
          final ch = manager.channelOf(id);
          if (ch == null || ch.isClosed) break;
          var existing = await part.exists() ? await part.length() : 0;
          if (existing > meta.size) {
            await part.delete();
            existing = 0;
          }
          d.received = existing;
          d.channel = ch;
          d.raf = await part.open(mode: FileMode.append);
          d.result = Completer<_Outcome>();
          _set(m.id, TransferState(TransferStatus.downloading, meta.size,
              received: existing));
          _armWatchdog(d);
          unawaited(ch.closed.then((_) {
            if (d.result != null && !d.result!.isCompleted) {
              d.result!.complete(_Outcome.interrupted);
            }
          }));
          try {
            await ch.send({'t': 'file_get', 'mid': m.id, 'offset': existing});
          } catch (_) {
            if (!d.result!.isCompleted) d.result!.complete(_Outcome.interrupted);
          }
          final outcome = await d.result!.future;
          d.watchdog?.cancel();
          await d.writeChain.catchError((_) {});
          await d.raf?.close();
          d.raf = null;
          if (outcome == _Outcome.ok) {
            states.remove(m.id);
            _changes.add(null);
            return;
          }
          if (outcome == _Outcome.interrupted) {
            final next = manager.channelOf(id);
            if (next != null && next != ch && !next.isClosed) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
              continue; // resume on the replacement connection
            }
            anyInterrupted = true;
          }
          if (outcome == _Outcome.badHash) anyBad = true;
          break;
        }
      }
      _set(
          m.id,
          anyInterrupted
              ? TransferState(TransferStatus.interrupted, meta.size,
                  received: d.received,
                  message: 'Transfer interrupted. Tap to resume.')
              : TransferState(
                  anyBad ? TransferStatus.failed : TransferStatus.unavailable,
                  meta.size,
                  message: anyBad
                      ? 'Integrity check failed'
                      : 'The device that has this file is not sharing it right now'));
    } catch (e) {
      _set(m.id,
          TransferState(TransferStatus.failed, meta.size, message: '$e'));
    } finally {
      d.watchdog?.cancel();
      await d.writeChain.catchError((_) {});
      await d.raf?.close().catchError((_) {});
      _downloads.remove(m.id);
      _changes.add(null);
    }
  }

  void _armWatchdog(_Download d) {
    d.watchdog?.cancel();
    d.watchdog = Timer(stallTimeout, () {
      if (d.result != null && !d.result!.isCompleted) {
        d.result!.complete(_Outcome.interrupted);
      }
    });
  }

  // --- protocol handling -----------------------------------------------------------

  Future<void> handle(PeerChannel ch, Map<String, dynamic> m) async {
    final mid = m['mid'];
    if (mid is! String) throw ProtocolException('file message without id');
    switch (m['t']) {
      case 'file_get':
        final off = m['offset'];
        if (off is! int || off < 0) throw ProtocolException('bad offset');
        unawaited(_serve(ch, mid, off));
      case 'file_start':
        break; // chunks carry their own offsets
      case 'file_chunk':
        final d = _downloads[mid];
        if (d == null || d.channel != ch || d.raf == null) return;
        final off = m['off'];
        final data = m['bin'];
        if (off is! int || data is! Uint8List || off != d.received) {
          _fail(d, _Outcome.interrupted);
          return;
        }
        final bytes = data;
        if (d.received + bytes.length > d.meta.size) {
          _fail(d, _Outcome.badHash);
          return;
        }
        final raf = d.raf!;
        d.writeChain = d.writeChain.then((_) => raf.writeFrom(bytes));
        await d.writeChain;
        d.received += bytes.length;
        final st = states[mid];
        if (st != null) st.received = d.received;
        _changes.add(null);
        _armWatchdog(d);
      case 'file_end':
        final d = _downloads[mid];
        if (d == null || d.channel != ch) return;
        // Hashing a big file takes longer than the stall timeout; the data
        // has all arrived, so the watchdog must not fire from here on.
        d.watchdog?.cancel();
        await d.writeChain.catchError((_) {});
        await d.raf?.close();
        d.raf = null;
        final ok = await store.finalizeDownload(mid, d.meta);
        _complete(d, ok ? _Outcome.ok : _Outcome.badHash);
      case 'file_err':
        final d = _downloads[mid];
        if (d == null || d.channel != ch) return;
        _complete(d, _Outcome.notFound);
    }
  }

  void _fail(_Download d, _Outcome o) => _complete(d, o);

  void _complete(_Download d, _Outcome o) {
    final r = d.result;
    if (r != null && !r.isCompleted) r.complete(o);
  }

  Future<void> _serve(PeerChannel ch, String mid, int offset) async {
    final att = await store.get(mid);
    if (att == null || offset > att.size) {
      await ch.send({'t': 'file_err', 'mid': mid, 'reason': 'not_found'})
          .catchError((_) {});
      return;
    }
    RandomAccessFile? raf;
    _serving++;
    _changes.add(null);
    try {
      raf = await File(att.path).open();
      await raf.setPosition(offset);
      await ch.send({'t': 'file_start', 'mid': mid, 'offset': offset});
      var pos = offset;
      while (pos < att.size) {
        if (ch.isClosed) return;
        final want = (att.size - pos) < chunkSize ? att.size - pos : chunkSize;
        final buf = await raf.read(want);
        if (buf.isEmpty) break;
        await ch.send({'t': 'file_chunk', 'mid': mid, 'off': pos, 'bin': buf});
        pos += buf.length;
      }
      await ch.send({'t': 'file_end', 'mid': mid});
    } catch (_) {
      // Channel died mid-transfer; the downloader resumes from its .part.
    } finally {
      await raf?.close();
      _serving--;
      _changes.add(null);
    }
  }
}
