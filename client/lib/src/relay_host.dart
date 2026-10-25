import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class _Session {
  _Session(this.id, this.socket, this.ip);
  final String id;
  final WebSocket socket;
  final String ip;
  String name = 'QuickSend';
  String roomHash = '';
  String publicKey = '';
  String auth = '';
  bool get joined => roomHash.isNotEmpty;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'ip': ip, 'publicKey': publicKey, 'auth': auth};
}

class _RoomGroup {
  _RoomGroup(this.id, this.name, this.ownerId, this.roomHash);
  final String id;
  final String name;
  final String ownerId;
  final String roomHash;
  final Set<String> members = {};
  final Set<String> invitees = {};
  final List<Map<String, dynamic>> messages = [];
  Map<String, dynamic> toJson(Map<String, _Session> sessions) => {
    'id': id, 'name': name, 'ownerId': ownerId,
    'members': members.map((id) => sessions[id]?.toJson()).whereType<Map<String, dynamic>>().toList(),
    'messages': messages,
  };
}

class _PendingTransfer {
  final String id;
  final String senderId;
  final Set<String> recipients;
  final Set<String> pending;
  final Set<String> accepted = {};
  final List<Map<String, dynamic>> files;
  final Map<String, dynamic> envelopes;
  final Map<String, Set<String>> waitingAcks = {};
  bool started = false;
  bool senderCompleted = false;
  final Set<String> awaitingVerification = {};
  Timer? timer;
  _PendingTransfer({required this.id, required this.senderId, required this.recipients, required this.files, required this.envelopes}) : pending = {...recipients};
}

/// In-memory LAN relay. Payload encryption/decryption stays entirely on endpoints.
class RelayHost {
  RelayHost({this.port = 4321});
  final int port;
  HttpServer? _http;
  final Map<String, _Session> _sessions = {};
  final Map<String, _RoomGroup> _groups = {};
  final Map<String, _PendingTransfer> _transfers = {};
  final _random = Random.secure();
  bool get isRunning => _http != null;
  int get boundPort => _http?.port ?? port;

  Future<void> start() async {
    if (_http != null) return;
    _http = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    _http!.listen((request) async {
      if (request.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        final id = _uuid();
        final session = _Session(id, socket, request.connectionInfo?.remoteAddress.address ?? 'unknown');
        _sessions[id] = session;
        socket.add(jsonEncode({'type': 'challenge', 'id': id}));
        socket.listen((data) {
          if (data is String) {
            try { _handleJson(session, Map<String, dynamic>.from(jsonDecode(data) as Map)); } catch (_) { _send(session, {'type': 'error', 'message': 'Invalid message'}); }
          } else if (data is List<int>) {
            _routeChunk(session, data);
          }
        }, onDone: () => _remove(session), onError: (_) => _remove(session), cancelOnError: true);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });
  }

  Future<void> stop() async {
    for (final transfer in _transfers.values.toList()) _cancelTransfer(transfer, 'LAN relay stopped');
    for (final session in _sessions.values.toList()) await session.socket.close(WebSocketStatus.goingAway);
    _sessions.clear(); _groups.clear(); _transfers.clear();
    await _http?.close(force: true); _http = null;
  }

  void _handleJson(_Session session, Map<String, dynamic> message) {
    if (!session.joined) {
      if (message['type'] != 'hello') { _send(session, {'type': 'error', 'message': 'Join a private room first'}); return; }
      final room = message['roomHash']; final publicKey = message['publicKey'];
      if (message['id'] != session.id || room is! String || !RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(room) || publicKey is! String || _tryBase64(publicKey)?.length != 32 || message['auth'] is! String) {
        _send(session, {'type': 'error', 'message': 'Invalid room key or public key'}); return;
      }
      session.roomHash = room.toLowerCase(); session.publicKey = publicKey; session.auth = message['auth'] as String;
      session.name = _clean(message['name'], max: 32, fallback: 'QuickSend');
      _send(session, {'type': 'welcome', ...session.toJson(), 'port': boundPort});
      _broadcastPeers(session.roomHash);
      return;
    }
    switch (message['type']) {
      case 'rename':
        session.name = _clean(message['name'], max: 32, fallback: 'QuickSend'); _broadcastPeers(session.roomHash); break;
      case 'ping': _send(session, {'type': 'pong'}); break;
      case 'group-create': _createGroup(session, message); break;
      case 'group-join': _joinGroup(session, message); break;
      case 'group-decline': _sendGroup(session, message, 'group-invite-declined'); break;
      case 'group-leave': _leaveGroup(session, message); break;
      case 'group-message': _sendGroupMessage(session, message); break;
      case 'request-transfer': _createTransfer(session, message); break;
      case 'decision': _decideTransfer(session, message); break;
      case 'chunk-ack': _ackChunk(session, message); break;
      case 'complete': _completeTransfer(session, message); break;
      case 'verified': _verifyTransfer(session, message); break;
      case 'cancel': _cancelForClient(session, message); break;
      default: _send(session, {'type': 'error', 'message': 'Unsupported operation'});
    }
  }

  void _createGroup(_Session owner, Map<String, dynamic> message) {
    final requested = (message['members'] as List? ?? const []).whereType<String>().toSet()..remove(owner.id);
    if (requested.length > 50 || requested.any((id) => _sessions[id] == null || _sessions[id]!.roomHash != owner.roomHash)) {
      _send(owner, {'type': 'error', 'message': 'Group members must be online in the same private room'}); return;
    }
    final id = _uuid();
    final group = _RoomGroup(id, _clean(message['name'], max: 48, fallback: 'LAN group'), owner.id, owner.roomHash)..members.add(owner.id)..invitees.addAll(requested);
    _groups[id] = group;
    for (final memberId in requested) {
      final member = _sessions[memberId]!;
      _send(member, {'type': 'group-invite', 'group': group.toJson(_sessions), 'inviter': owner.toJson()});
    }
    _send(owner, {'type': 'group-created', 'group': group.toJson(_sessions)});
  }

  void _joinGroup(_Session member, Map<String, dynamic> message) {
    final group = _groups[message['groupId']];
    if (group == null || group.roomHash != member.roomHash || (!group.invitees.remove(member.id) && !group.members.contains(member.id))) return;
    group.members.add(member.id);
    _broadcastGroup(group, {'type': 'group-updated', 'group': group.toJson(_sessions)});
  }

  void _leaveGroup(_Session member, Map<String, dynamic> message) {
    final group = _groups[message['groupId']];
    if (group == null || !group.members.remove(member.id)) return;
    if (group.members.isEmpty) _groups.remove(group.id);
    else _broadcastGroup(group, {'type': 'group-updated', 'group': group.toJson(_sessions), 'leftId': member.id});
  }

  void _sendGroupMessage(_Session sender, Map<String, dynamic> message) {
    final group = _groups[message['groupId']];
    final ciphertext = message['ciphertext']; final nonce = message['nonce']; final id = message['id']; final auth = message['auth'];
    if (group == null || !group.members.contains(sender.id) || ciphertext is! String || ciphertext.length > 12000 || nonce is! String || _tryBase64(nonce)?.length != 12 || (_tryBase64(ciphertext)?.length ?? 0) < 16 || id is! String || !RegExp(r'^[a-f0-9-]{36}$', caseSensitive: false).hasMatch(id) || auth is! String) return;
    final item = {'id': id, 'groupId': group.id, 'senderId': sender.id, 'senderName': sender.name, 'senderIp': sender.ip, 'ciphertext': ciphertext, 'nonce': nonce, 'auth': auth, 'createdAt': DateTime.now().toUtc().toIso8601String()};
    group.messages.add(item);
    if (group.messages.length > 300) group.messages.removeAt(0);
    _broadcastGroup(group, {'type': 'group-message', 'message': item});
  }

  void _sendGroup(_Session session, Map<String, dynamic> message, String type) {
    final group = _groups[message['groupId']];
    if (group == null) return;
    _send(_sessions[group.ownerId], {'type': type, 'groupId': group.id, 'peer': session.toJson()});
  }

  void _createTransfer(_Session sender, Map<String, dynamic> message) {
    final id = message['transferId'];
    final recipientIds = (message['recipients'] as List? ?? const []).whereType<String>().toSet();
    final rawFiles = (message['files'] as List? ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final rawEnvelopes = message['keyEnvelopes'];
    final envelopes = rawEnvelopes is Map ? Map<String, dynamic>.from(rawEnvelopes) : <String, dynamic>{};
    if (id is! String || !RegExp(r'^[a-f0-9-]{36}$', caseSensitive: false).hasMatch(id) || recipientIds.isEmpty || recipientIds.length > 50 || rawFiles.isEmpty || rawFiles.length > 100) {
      _send(sender, {'type': 'transfer-error', 'transferId': id, 'message': 'Invalid transfer manifest'}); return;
    }
    final recipients = recipientIds.map((id) => _sessions[id]).toList();
    if (recipientIds.contains(sender.id) || recipients.any((peer) => peer == null || peer.roomHash != sender.roomHash)) {
      _send(sender, {'type': 'transfer-error', 'transferId': id, 'message': 'Recipient is offline or outside this room'}); return;
    }
    var total = 0;
    final files = <Map<String, dynamic>>[];
    for (final file in rawFiles) {
      final size = file['size'];
      if (size is! int || size < 0 || size > 100 * 1024 * 1024 * 1024) {
        _send(sender, {'type': 'transfer-error', 'transferId': id, 'message': 'Invalid file metadata'}); return;
      }
      total += size;
      files.add({'size': size});
    }
    if (total > 500 * 1024 * 1024 * 1024 || _transfers.containsKey(id)) {
      _send(sender, {'type': 'transfer-error', 'transferId': id, 'message': 'Transfer exceeds the limit or duplicates an active ID'}); return;
    }
    for (final peerId in recipientIds) {
      final envelope = envelopes[peerId];
      if (envelope is! Map || _tryBase64(envelope['nonce'])?.length != 12 || (_tryBase64(envelope['ciphertext'])?.length ?? 0) < 48 || (_tryBase64(envelope['ciphertext'])?.length ?? 0) > 1024 * 1024) {
        _send(sender, {'type': 'transfer-error', 'transferId': id, 'message': 'Invalid recipient key envelope'}); return;
      }
    }
    final transfer = _PendingTransfer(id: id, senderId: sender.id, recipients: recipientIds, files: files, envelopes: envelopes);
    transfer.timer = Timer(const Duration(minutes: 2), () => _cancelTransfer(transfer, 'Recipient approval timed out'));
    _transfers[id] = transfer;
    for (final peer in recipients.cast<_Session>()) _send(peer, {'type': 'incoming-request', 'transferId': id, 'sender': sender.toJson(), 'files': files});
    _send(sender, {'type': 'transfer-state', 'transferId': id, 'state': 'waiting'});
  }

  void _decideTransfer(_Session peer, Map<String, dynamic> message) {
    final transfer = _transfers[message['transferId']];
    if (transfer == null || !transfer.recipients.contains(peer.id) || !transfer.pending.remove(peer.id)) return;
    if (message['accept'] == true) transfer.accepted.add(peer.id);
    _send(_sessions[transfer.senderId], {'type': 'recipient-decision', 'transferId': transfer.id, 'peerId': peer.id, 'name': peer.name, 'accepted': message['accept'] == true});
    if (transfer.pending.isNotEmpty) return;
    transfer.timer?.cancel();
    if (transfer.accepted.isEmpty) { _cancelTransfer(transfer, 'No recipient accepted'); return; }
    transfer.started = true;
    _send(_sessions[transfer.senderId], {'type': 'transfer-ready', 'transferId': transfer.id, 'accepted': transfer.accepted.map((id) => _sessions[id]?.toJson()).whereType<Map<String, dynamic>>().toList()});
    for (final id in transfer.accepted) _send(_sessions[id], {'type': 'transfer-start', 'transferId': transfer.id, 'sender': _sessions[transfer.senderId]?.toJson(), 'files': transfer.files, 'keyEnvelope': transfer.envelopes[id]});
    transfer.timer = Timer(const Duration(hours: 2), () => _cancelTransfer(transfer, 'Transfer expired'));
  }

  void _routeChunk(_Session sender, List<int> frame) {
    if (frame.length < 4 + 2 + 12 + 16 || frame.length > 256 * 1024 + 4096) return;
    final view = ByteData.sublistView(Uint8List.fromList(frame));
    final metaLength = view.getUint32(0, Endian.big);
    if (metaLength > 2048 || 4 + metaLength + 28 > frame.length) return;
    Map<String, dynamic> meta;
    try { meta = Map<String, dynamic>.from(jsonDecode(utf8.decode(frame.sublist(4, 4 + metaLength))) as Map); } catch (_) { return; }
    final transfer = _transfers[meta['transferId']];
    final index = meta['fileIndex']; final sequence = meta['seq'];
    if (transfer == null || !transfer.started || transfer.senderId != sender.id || index is! int || index < 0 || index >= transfer.files.length || sequence is! int || sequence < 0) return;
    final ackKey = '$index:$sequence';
    if (transfer.waitingAcks.containsKey(ackKey)) return;
    transfer.waitingAcks[ackKey] = {...transfer.accepted};
    for (final recipientId in transfer.accepted) {
      final target = _sessions[recipientId];
      if (target?.socket.readyState == WebSocket.open) target!.socket.add(frame);
    }
  }

  void _ackChunk(_Session peer, Map<String, dynamic> message) {
    final transfer = _transfers[message['transferId']];
    final index = message['fileIndex']; final sequence = message['seq'];
    if (transfer == null || !transfer.accepted.contains(peer.id) || index is! int || sequence is! int) return;
    final waiting = transfer.waitingAcks['$index:$sequence'];
    if (waiting == null) return;
    waiting.remove(peer.id);
    if (waiting.isEmpty) {
      transfer.waitingAcks.remove('$index:$sequence');
      _send(_sessions[transfer.senderId], {'type': 'chunk-acked', 'transferId': transfer.id, 'fileIndex': index, 'seq': sequence});
    }
  }

  void _completeTransfer(_Session sender, Map<String, dynamic> message) {
    final transfer = _transfers[message['transferId']];
    if (transfer == null || !transfer.started || transfer.senderId != sender.id || transfer.waitingAcks.isNotEmpty || transfer.senderCompleted) return;
    transfer.senderCompleted = true;
    transfer.awaitingVerification.addAll(transfer.accepted);
    for (final id in transfer.accepted) _send(_sessions[id], {'type': 'transfer-complete', 'transferId': transfer.id});
    transfer.timer?.cancel();
    transfer.timer = Timer(const Duration(hours: 12), () => _cancelTransfer(transfer, 'Recipient integrity confirmation timed out'));
  }

  void _verifyTransfer(_Session recipient, Map<String, dynamic> message) {
    final transfer = _transfers[message['transferId']];
    if (transfer == null || !transfer.senderCompleted || !transfer.awaitingVerification.remove(recipient.id) || !transfer.accepted.contains(recipient.id)) return;
    if (message['ok'] != true) { _cancelTransfer(transfer, 'A recipient failed final integrity verification'); return; }
    if (transfer.awaitingVerification.isEmpty) {
      _send(_sessions[transfer.senderId], {'type': 'transfer-finished', 'transferId': transfer.id});
      transfer.timer?.cancel(); _transfers.remove(transfer.id);
    }
  }

  void _cancelForClient(_Session peer, Map<String, dynamic> message) {
    final transfer = _transfers[message['transferId']];
    if (transfer != null && (transfer.senderId == peer.id || transfer.recipients.contains(peer.id))) _cancelTransfer(transfer, '${peer.name} cancelled the transfer');
  }

  void _cancelTransfer(_PendingTransfer transfer, String reason) {
    if (!_transfers.containsKey(transfer.id)) return;
    transfer.timer?.cancel(); _transfers.remove(transfer.id);
    _send(_sessions[transfer.senderId], {'type': 'transfer-error', 'transferId': transfer.id, 'message': reason});
    for (final id in transfer.recipients) _send(_sessions[id], {'type': 'transfer-cancelled', 'transferId': transfer.id, 'message': reason});
  }

  void _remove(_Session session) {
    if (_sessions.remove(session.id) == null) return;
    for (final group in _groups.values.toList()) {
      if (group.members.remove(session.id)) {
        if (group.members.isEmpty) _groups.remove(group.id);
        else _broadcastGroup(group, {'type': 'group-updated', 'group': group.toJson(_sessions), 'leftId': session.id});
      }
    }
    for (final transfer in _transfers.values.toList()) {
      if (transfer.senderId == session.id) _cancelTransfer(transfer, 'Sender disconnected');
      else if (transfer.recipients.contains(session.id)) _cancelTransfer(transfer, 'Recipient disconnected');
    }
    if (session.joined) _broadcastPeers(session.roomHash);
  }

  void _broadcastPeers(String roomHash) {
    final peers = _sessions.values.where((session) => session.roomHash == roomHash).map((session) => session.toJson()).toList();
    for (final session in _sessions.values.where((session) => session.roomHash == roomHash)) _send(session, {'type': 'peers', 'peers': peers});
  }
  void _broadcastGroup(_RoomGroup group, Map<String, dynamic> message) {
    for (final id in group.members) _send(_sessions[id], message);
  }
  void _send(_Session? session, Map<String, dynamic> message) {
    if (session?.socket.readyState == WebSocket.open) session!.socket.add(jsonEncode(message));
  }
  String _uuid() => '${_hex(4)}-${_hex(2)}-4${_hex(2).substring(1)}-${(8 + _random.nextInt(4)).toRadixString(16)}${_hex(2).substring(1)}-${_hex(6)}';
  String _hex(int bytes) => List.generate(bytes, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  String _clean(dynamic value, {required int max, required String fallback}) {
    if (value is! String) return fallback;
    final cleaned = value.trim().replaceAll(RegExp(r'[\x00-\x1f]'), '');
    return cleaned.isEmpty ? fallback : cleaned.substring(0, min(max, cleaned.length));
  }
  Uint8List? _tryBase64(dynamic value) { if (value is! String) return null; try { return Uint8List.fromList(base64.decode(value)); } catch (_) { return null; } }
}
