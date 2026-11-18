/// Versioned wire protocol (v1). All application messages are JSON objects
/// with a `t` (type) field, carried inside the encrypted channel.
///
///   session      {t, v, trusted}        both sides, right after handshake
///   pair_decision{t, accept}            pairing only
///   sync_hello   {t, vector}            vector = {originDeviceId: maxSeq}
///   msgs         {t, msgs:[Message]}    ascending per origin, contiguous
///   vector       {t, vector}            "this is what I now have" (ack)
///   ping / bye   {t[, reason]}
const protocolVersion = 2;

/// Max size of one encrypted frame (after length prefix).
const maxFrameBytes = 8 * 1024 * 1024;

/// Edits are ordinary append-only messages of kind 'edit' whose body is
/// {"t": targetMessageId, "b": newText}. The latest edit (by time, then
/// device id, then seq) wins; the original is never rewritten.
const editKind = 'edit';

/// Max UTF-8 size of one text message body.
const maxTextBytes = 1024 * 1024;

final _deviceIdRe = RegExp(r'^[0-9a-f]{32}$');

class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;
  @override
  String toString() => 'ProtocolException: $message';
}

/// An immutable, append-only inbox item. Identified globally by [id]; ordered
/// per originating device by [originSeq] (contiguous, starting at 1), which is
/// what makes sync idempotent and gap-free.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.originDeviceId,
    required this.originName,
    required this.originSeq,
    required this.createdAt,
    required this.kind,
    required this.body,
    this.editedAt,
  });

  final String id;
  final String originDeviceId;
  final String originName;
  final int originSeq;

  /// Milliseconds since epoch (UTC) according to the origin device's clock.
  final int createdAt;

  /// 'text' for now. Unknown kinds are stored and synced untouched so that
  /// newer app versions never stall an older one's sequence.
  final String kind;
  final String body;

  /// Local view only (never sent): time of the latest applied edit, if any.
  final int? editedAt;

  ChatMessage withEdit(String newBody, int at) => ChatMessage(
      id: id,
      originDeviceId: originDeviceId,
      originName: originName,
      originSeq: originSeq,
      createdAt: createdAt,
      kind: kind,
      body: newBody,
      editedAt: at);

  Map<String, dynamic> toJson() => {
        'id': id,
        'od': originDeviceId,
        'on': originName,
        'seq': originSeq,
        'ts': createdAt,
        'k': kind,
        'b': body,
      };

  factory ChatMessage.fromJson(Object? raw) {
    if (raw is! Map) throw ProtocolException('message is not an object');
    final id = raw['id'];
    final od = raw['od'];
    final on = raw['on'];
    final seq = raw['seq'];
    final ts = raw['ts'];
    final k = raw['k'];
    final b = raw['b'];
    if (id is! String || id.isEmpty || id.length > 64) {
      throw ProtocolException('bad message id');
    }
    if (od is! String || !_deviceIdRe.hasMatch(od)) {
      throw ProtocolException('bad origin device id');
    }
    if (on is! String || on.length > 64) {
      throw ProtocolException('bad origin name');
    }
    if (seq is! int || seq < 1) throw ProtocolException('bad sequence');
    if (ts is! int || ts < 0) throw ProtocolException('bad timestamp');
    if (k is! String || k.isEmpty || k.length > 16) {
      throw ProtocolException('bad kind');
    }
    if (b is! String) throw ProtocolException('bad body');
    return ChatMessage(
        id: id,
        originDeviceId: od,
        originName: on,
        originSeq: seq,
        createdAt: ts,
        kind: k,
        body: b);
  }

  @override
  bool operator ==(Object other) =>
      other is ChatMessage &&
      other.id == id &&
      other.originDeviceId == originDeviceId &&
      other.originSeq == originSeq &&
      other.createdAt == createdAt &&
      other.kind == kind &&
      other.body == body &&
      other.originName == originName;

  @override
  int get hashCode => Object.hash(id, originDeviceId, originSeq);
}

Map<String, int> parseVector(Object? raw) {
  if (raw is! Map) throw ProtocolException('vector is not an object');
  final out = <String, int>{};
  raw.forEach((k, v) {
    if (k is! String || !_deviceIdRe.hasMatch(k) || v is! int || v < 0) {
      throw ProtocolException('bad vector entry');
    }
    out[k] = v;
  });
  return out;
}
