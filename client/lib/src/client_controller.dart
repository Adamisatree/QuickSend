import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'relay_host.dart';

class IncomingRequest {
  const IncomingRequest({required this.transferId, required this.senderName, required this.senderIp, required this.fileCount, required this.totalBytes});
  final String transferId;
  final String senderName;
  final String senderIp;
  final int fileCount;
  final int totalBytes;
}

class GroupInvite {
  const GroupInvite({required this.group, required this.inviter});
  final ChatGroup group;
  final Peer inviter;
}

class _Receiving {
  _Receiving(this.key, this.files, this.root);
  final SecretKey key;
  final List<Map<String, dynamic>> files;
  final String root;
  final Map<int, int> nextSeq = {};
  final Map<int, int> received = {};
}

class ClientController extends ChangeNotifier {
  ClientController() : _relayHost = RelayHost();
  RelayHost _relayHost;
  final _random = Random.secure();
  final X25519 _x25519 = X25519();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final Chacha20 _aead = Chacha20.poly1305Aead();
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  SimpleKeyPair? _keyPair;
  SecretKey? _roomSecret;
  String? _myId;
  String _name = 'QuickSend';
  String _roomHash = '';
  String _endpoint = '';
  List<String> localAddresses = const [];
  RoomConnectionState connection = RoomConnectionState.disconnected;
  String? error;
  final Map<String, Peer> peers = {};
  final Map<String, ChatGroup> groups = {};
  final Map<String, IncomingRequest> incoming = {};
  final Map<String, GroupInvite> groupInvites = {};
  final Map<String, _Receiving> _receivers = {};
  final Map<String, Completer<void>> _acks = {};
  final Map<String, Map<String, dynamic>> _pendingSend = {};
  final List<TransferProgress> transfers = [];
  final Map<String, List<String>> savedFiles = {};
  Future<void> _binaryQueue = Future<void>.value();
  bool get hosting => _relayHost.isRunning;
  int get hostPort => _relayHost.boundPort;
  String get endpoint => _endpoint;
  String? get myId => _myId;

  Future<void> startHosting({int port = 4321}) async {
    try {
      if (_relayHost.port != port) _relayHost = RelayHost(port: port);
      await _relayHost.start();
      final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      localAddresses = interfaces.expand((interface) => interface.addresses).where((address) => !address.isLoopback).map((address) => address.address).toSet().toList();
      error = null;
    }
    catch (e) { error = 'Could not start LAN relay on port $port: $e'; }
    notifyListeners();
  }

  Future<void> stopHosting() async {
    await _relayHost.stop();
    if (_channel != null) await disconnect();
    notifyListeners();
  }

  Future<void> connect({required String host, required int port, required String roomKey, required String name}) async {
    await disconnect();
    final cleanKey = roomKey.trim();
    if (cleanKey.length < 12) { error = 'Use a private room key with at least 12 characters (a random phrase is safer).'; notifyListeners(); return; }
    if (cleanKey.length > 256) { error = 'Room key is too long.'; notifyListeners(); return; }
    final address = InternetAddress.tryParse(host.trim());
    if (address == null || address.type != InternetAddressType.IPv4) { error = 'Enter a valid IPv4 address on the same local network.'; notifyListeners(); return; }
    if (port < 1 || port > 65535) { error = 'Enter a port from 1 to 65535.'; notifyListeners(); return; }
    connection = RoomConnectionState.connecting; error = null; notifyListeners();
    try {
      _name = name.trim().isEmpty ? 'QuickSend' : name.trim().substring(0, min(name.trim().length, 32));
      _roomHash = digest.sha256.convert(utf8.encode(cleanKey)).toString();
      _roomSecret = await _hkdf.deriveKey(secretKey: SecretKey(utf8.encode(cleanKey)), nonce: Uint8List(16), info: utf8.encode('QuickSend v2 room authentication'));
      _keyPair = await _x25519.newKeyPair();
      final channel = WebSocketChannel.connect(Uri(scheme: 'ws', host: address.address, port: port, path: '/ws'));
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 8));
      _subscription = channel.stream.listen(_onSocketData, onError: (Object e) { _setDisconnected('Connection error: $e'); }, onDone: () { _setDisconnected(null); });
      // The relay first assigns an opaque connection ID; the signed hello follows the challenge.
      _endpoint = '${address.address}:$port';
    } catch (e) {
      _setDisconnected('Could not connect: $e');
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _subscription?.cancel(); _subscription = null;
    await _channel?.sink.close(); _channel = null;
    connection = RoomConnectionState.disconnected; _myId = null; _roomSecret = null; _keyPair = null;
    peers.clear(); groups.clear(); incoming.clear(); groupInvites.clear(); _receivers.clear(); _acks.clear();
    notifyListeners();
  }

  void setName(String value) {
    final clean = value.trim(); if (clean.isEmpty) return;
    _name = clean.substring(0, min(clean.length, 32));
    _send({'type': 'rename', 'name': _name});
  }

  Future<void> createGroup(String name, Iterable<String> memberIds) async => _send({'type': 'group-create', 'name': name, 'members': memberIds.toList()});
  Future<void> respondGroupInvite(String groupId, bool accept) async {
    groupInvites.remove(groupId);
    if (accept) _send({'type': 'group-join', 'groupId': groupId}); else _send({'type': 'group-decline', 'groupId': groupId});
    notifyListeners();
  }
  Future<void> leaveGroup(String groupId) async { _send({'type': 'group-leave', 'groupId': groupId}); groups.remove(groupId); notifyListeners(); }
  Future<void> sendChat(String groupId, String text) async {
    if (text.trim().isEmpty || text.length > 4000 || _roomSecret == null || _myId == null) return;
    final id = _uuid(); final nonce = _randomBytes(12);
    final key = await _hkdf.deriveKey(secretKey: _roomSecret!, nonce: Uint8List(16), info: utf8.encode('QuickSend v2 group chat|$groupId'));
    final box = await _aead.encrypt(utf8.encode(text.trim()), secretKey: key, nonce: nonce);
    final cipher = base64.encode([...box.cipherText, ...box.mac.bytes]);
    final nonceText = base64.encode(nonce);
    final mac = await Hmac.sha256().calculateMac(utf8.encode('$id|$groupId|$_myId|$nonceText|$cipher'), secretKey: _roomSecret!);
    _send({'type': 'group-message', 'groupId': groupId, 'id': id, 'nonce': nonceText, 'ciphertext': cipher, 'auth': base64.encode(mac.bytes)});
  }

  Future<void> sendFiles({required List<SharedFile> files, required Iterable<String> recipientIds}) async {
    if (connection != RoomConnectionState.connected || _myId == null || _keyPair == null) { error = 'Connect to a room before sending.'; notifyListeners(); return; }
    final ids = recipientIds.toSet();
    if (files.isEmpty || ids.isEmpty) { error = 'Select at least one file and one recipient.'; notifyListeners(); return; }
    if (files.length > 100 || files.fold<int>(0, (sum, file) => sum + file.size) > 500 * 1024 * 1024 * 1024) { error = 'This transfer exceeds the 100-file or 500 GiB safety limit.'; notifyListeners(); return; }
    try {
      final manifests = <Map<String, dynamic>>[];
      for (final item in files) {
        final file = File(item.path);
        if (!await file.exists()) throw Exception('${item.name} no longer exists');
        final actualSize = await file.length();
        if (actualSize != item.size) throw Exception('${item.name} changed before sending');
        final hash = await digest.sha256.bind(file.openRead()).first;
        manifests.add({'name': item.name, 'relativePath': _safePath(item.relativePath), 'size': actualSize, 'sha256': hash.toString(), 'type': 'application/octet-stream'});
      }
      final transferId = _uuid();
      final transferKeyBytes = _randomBytes(32);
      final transferKey = SecretKey(transferKeyBytes);
      final envelopes = <String, dynamic>{};
      for (final recipientId in ids) {
        final peer = peers[recipientId];
        if (peer == null || !await _verifyPeer(peer)) throw Exception('Peer identity check failed for ${peer?.name ?? recipientId}. Reconnect to the private room.');
        final shared = await _x25519.sharedSecretKey(keyPair: _keyPair!, remotePublicKey: SimplePublicKey(base64.decode(peer.publicKey), type: KeyPairType.x25519));
        final wrappingKey = await _hkdf.deriveKey(secretKey: shared, nonce: utf8.encode(transferId), info: utf8.encode('QuickSend v2 key wrap|${peer.id}'));
        final nonce = _randomBytes(12);
        final payload = utf8.encode(jsonEncode({'key': base64.encode(transferKeyBytes), 'files': manifests}));
        final box = await _aead.encrypt(payload, secretKey: wrappingKey, nonce: nonce, aad: utf8.encode('QuickSend v2 manifest|$transferId|${peer.id}'));
        envelopes[peer.id] = {'nonce': base64.encode(nonce), 'ciphertext': base64.encode([...box.cipherText, ...box.mac.bytes])};
      }
      final total = manifests.fold<int>(0, (sum, file) => sum + (file['size'] as int));
      final progress = TransferProgress(id: transferId, label: '${files.length} file${files.length == 1 ? '' : 's'}', totalBytes: total, peerLabel: ids.map((id) => peers[id]?.name ?? '?').join(', '));
      transfers.insert(0, progress); _pendingSend[transferId] = {'files': files, 'key': transferKey, 'progress': progress};
      _send({'type': 'request-transfer', 'transferId': transferId, 'recipients': ids.toList(), 'files': manifests.map((f) => {'size': f['size']}).toList(), 'keyEnvelopes': envelopes});
      error = null; notifyListeners();
    } catch (e) { error = 'Transfer could not be prepared: $e'; notifyListeners(); }
  }

  Future<void> decideIncoming(String id, bool accept) async {
    final request = incoming.remove(id);
    _send({'type': 'decision', 'transferId': id, 'accept': accept});
    notifyListeners();
    if (request == null || !accept) return;
  }

  Future<void> cancelTransfer(String id) async { _send({'type': 'cancel', 'transferId': id}); }
  void clearError() { error = null; notifyListeners(); }

  void _onSocketData(dynamic raw) {
    if (raw is List<int>) {
      final bytes = Uint8List.fromList(raw);
      _binaryQueue = _binaryQueue.then((_) => _handleChunk(bytes)).catchError((Object e) { error = 'Could not receive chunk: $e'; notifyListeners(); });
      return;
    }
    if (raw is! String) return;
    try {
      final message = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      switch (message['type']) {
        case 'challenge':
          _sendAuthenticatedHello(message['id'] as String? ?? '');
          break;
        case 'welcome':
          _myId = message['id'] as String?; connection = RoomConnectionState.connected;
          break;
        case 'peers':
          _replacePeers(message['peers'] as List? ?? const []);
          break;
        case 'group-created': case 'group-updated':
          _loadGroup(Map<String, dynamic>.from(message['group'] as Map));
          break;
        case 'group-invite':
          final rawGroup = Map<String, dynamic>.from(message['group'] as Map);
          final inviter = Peer.fromJson(Map<String, dynamic>.from(message['inviter'] as Map));
          _verifyPeer(inviter).then((valid) { if (valid) { groupInvites[rawGroup['id'] as String] = GroupInvite(group: ChatGroup.fromJson(rawGroup), inviter: inviter); notifyListeners(); } });
          break;
        case 'group-message':
          _receiveGroupMessage(Map<String, dynamic>.from(message['message'] as Map));
          break;
        case 'incoming-request':
          final sender = Peer.fromJson(Map<String, dynamic>.from(message['sender'] as Map));
          final id = message['transferId'] as String? ?? '';
          final files = (message['files'] as List? ?? const []).whereType<Map>().toList();
          if (id.isNotEmpty) {
            _verifyPeer(sender).then((valid) {
              if (!valid) { _send({'type': 'decision', 'transferId': id, 'accept': false}); error = 'Rejected a transfer with an invalid peer identity.'; }
              else { incoming[id] = IncomingRequest(transferId: id, senderName: sender.name, senderIp: sender.ip, fileCount: files.length, totalBytes: files.fold<int>(0, (sum, file) => sum + ((file['size'] as num?)?.toInt() ?? 0))); }
              notifyListeners();
            });
          }
          break;
        case 'transfer-ready':
          _startSending(message);
          break;
        case 'transfer-start':
          _startReceiving(message);
          break;
        case 'chunk-acked':
          final key = '${message['transferId']}:${message['fileIndex']}:${message['seq']}';
          final ack = _acks.remove(key); if (ack != null && !ack.isCompleted) ack.complete();
          break;
        case 'recipient-decision':
          final progress = _findTransfer(message['transferId']);
          if (progress != null && message['accepted'] != true) progress.state = TransferState.failed;
          break;
        case 'transfer-state':
          break;
        case 'transfer-finished': case 'transfer-complete':
          _finishTransfer(message['transferId'] as String? ?? '');
          break;
        case 'transfer-cancelled': case 'transfer-error':
          final id = message['transferId'] as String? ?? '';
          final progress = _findTransfer(id); if (progress != null) progress.state = TransferState.failed;
          _pendingSend.remove(id); _receivers.remove(id);
          error = message['message'] as String? ?? 'Transfer failed';
          break;
        case 'error': error = message['message'] as String? ?? 'Relay error'; break;
        case 'pong': break;
      }
      notifyListeners();
    } catch (e) { error = 'Invalid relay message: $e'; notifyListeners(); }
  }

  Future<void> _sendAuthenticatedHello(String id) async {
    try {
      if (id.isEmpty || _keyPair == null || _roomSecret == null) throw Exception('Missing challenge or session key');
      final publicKey = await _keyPair!.extractPublicKey();
      final publicText = base64.encode(publicKey.bytes);
      final mac = await Hmac.sha256().calculateMac(utf8.encode('$id|$publicText'), secretKey: _roomSecret!);
      _channel?.sink.add(jsonEncode({'type': 'hello', 'id': id, 'name': _name, 'roomHash': _roomHash, 'publicKey': publicText, 'auth': base64.encode(mac.bytes)}));
    } catch (e) { _setDisconnected('Could not authenticate the room: $e'); }
  }

  void _replacePeers(List<dynamic> list) {
    final next = <String, Peer>{};
    for (final raw in list.whereType<Map>()) {
      final peer = Peer.fromJson(Map<String, dynamic>.from(raw));
      if (peer.id.isNotEmpty && peer.publicKey.isNotEmpty) next[peer.id] = peer;
    }
    peers..clear()..addAll(next);
  }

  Future<void> _loadGroup(Map<String, dynamic> json) async {
    final raw = ChatGroup.fromJson(json);
    final messages = <ChatMessage>[];
    for (final rawMessage in (json['messages'] as List? ?? const []).whereType<Map>()) {
      final decoded = await _decodeGroupMessage(Map<String, dynamic>.from(rawMessage));
      if (decoded != null) messages.add(decoded);
    }
    groups[raw.id] = ChatGroup(id: raw.id, name: raw.name, ownerId: raw.ownerId, members: raw.members, messages: messages);
    notifyListeners();
  }

  Future<void> _receiveGroupMessage(Map<String, dynamic> json) async {
    try {
      final message = await _decodeGroupMessage(json);
      if (message == null) return;
      final group = groups[message.groupId];
      if (group != null) groups[message.groupId] = ChatGroup(id: group.id, name: group.name, ownerId: group.ownerId, members: group.members, messages: [...group.messages, message]);
      notifyListeners();
    } catch (_) { error = 'Encrypted group message failed verification.'; notifyListeners(); }
  }

  Future<ChatMessage?> _decodeGroupMessage(Map<String, dynamic> json) async {
    try {
      if (_roomSecret == null) return null;
      final id = json['id'] as String; final groupId = json['groupId'] as String; final senderId = json['senderId'] as String;
      final cipher = json['ciphertext'] as String; final nonceText = json['nonce'] as String;
      final expected = await Hmac.sha256().calculateMac(utf8.encode('$id|$groupId|$senderId|$nonceText|$cipher'), secretKey: _roomSecret!);
      if (!_constantTimeEqual(expected.bytes, base64.decode(json['auth'] as String))) return null;
      final key = await _hkdf.deriveKey(secretKey: _roomSecret!, nonce: Uint8List(16), info: utf8.encode('QuickSend v2 group chat|$groupId'));
      final combined = base64.decode(cipher);
      final text = utf8.decode(await _aead.decrypt(SecretBox(combined.sublist(0, combined.length - 16), nonce: base64.decode(nonceText), mac: Mac(combined.sublist(combined.length - 16))), secretKey: key));
      return ChatMessage(id: id, groupId: groupId, senderId: senderId, senderName: json['senderName'] as String? ?? 'peer', senderIp: json['senderIp'] as String? ?? '—', text: text, createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now());
    } catch (_) { return null; }
  }

  Future<bool> _verifyPeer(Peer peer) async {
    if (peer.publicKey.isEmpty || peer.id.isEmpty || _roomSecret == null) return false;
    try {
      final mac = await Hmac.sha256().calculateMac(utf8.encode('${peer.id}|${peer.publicKey}'), secretKey: _roomSecret!);
      final tagged = base64.decode(peer.auth);
      return _constantTimeEqual(mac.bytes, tagged);
    } catch (_) { return false; }
  }

  Future<void> _startSending(Map<String, dynamic> message) async {
    final id = message['transferId'] as String? ?? '';
    final data = _pendingSend[id]; if (data == null) return;
    final accepted = (message['accepted'] as List? ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)['id'] as String?).whereType<String>().toSet();
    if (accepted.isEmpty) return;
    final files = data['files'] as List<SharedFile>;
    final key = data['key'] as SecretKey;
    final progress = data['progress'] as TransferProgress..state = TransferState.running;
    final window = <String>[];
    try {
      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        final source = await File(files[fileIndex].path).open(mode: FileMode.read);
        var seq = 0;
        try {
          while (true) {
            final bytes = await source.read(256 * 1024);
            if (bytes.isEmpty) break;
            final ackKey = '$id:$fileIndex:$seq';
            final ack = Completer<void>(); _acks[ackKey] = ack; window.add(ackKey);
            final nonce = _randomBytes(12);
            final metadata = utf8.encode(jsonEncode({'transferId': id, 'fileIndex': fileIndex, 'seq': seq}));
            final box = await _aead.encrypt(bytes, secretKey: key, nonce: nonce, aad: metadata);
            final frame = BytesBuilder(copy: false)..add(_u32(metadata.length))..add(metadata)..add(nonce)..add(box.cipherText)..add(box.mac.bytes);
            _channel?.sink.add(frame.takeBytes());
            progress.received += bytes.length; seq++;
            if (window.length >= 8) { await _acks.remove(window.removeAt(0))?.future.timeout(const Duration(seconds: 90)); }
            notifyListeners();
          }
        } finally { await source.close(); }
        for (final ackKey in window.toList()) { await _acks.remove(ackKey)?.future.timeout(const Duration(seconds: 90)); window.remove(ackKey); }
      }
      _send({'type': 'complete', 'transferId': id});
    } catch (e) {
      progress.state = TransferState.failed; _send({'type': 'cancel', 'transferId': id}); error = 'Transfer failed: $e';
    }
    notifyListeners();
  }

  Future<void> _startReceiving(Map<String, dynamic> message) async {
    final id = message['transferId'] as String? ?? '';
    try {
      if (_roomSecret == null || _keyPair == null || _myId == null) throw Exception('Not connected');
      final sender = Peer.fromJson(Map<String, dynamic>.from(message['sender'] as Map));
      if (!await _verifyPeer(sender)) throw Exception('Sender identity did not verify');
      final envelope = Map<String, dynamic>.from(message['keyEnvelope'] as Map);
      final shared = await _x25519.sharedSecretKey(keyPair: _keyPair!, remotePublicKey: SimplePublicKey(base64.decode(sender.publicKey), type: KeyPairType.x25519));
      final wrappingKey = await _hkdf.deriveKey(secretKey: shared, nonce: utf8.encode(id), info: utf8.encode('QuickSend v2 key wrap|$_myId'));
      final combined = base64.decode(envelope['ciphertext'] as String);
      if (combined.length < 16) throw Exception('Invalid encrypted manifest');
      final plain = await _aead.decrypt(SecretBox(combined.sublist(0, combined.length - 16), nonce: base64.decode(envelope['nonce'] as String), mac: Mac(combined.sublist(combined.length - 16))), secretKey: wrappingKey, aad: utf8.encode('QuickSend v2 manifest|$id|$_myId'));
      final payload = Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map);
      final keyBytes = base64.decode(payload['key'] as String);
      final manifest = (payload['files'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final publicFiles = (message['files'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (keyBytes.length != 32 || manifest.length != publicFiles.length || manifest.length > 100) throw Exception('Manifest does not match');
      for (var i = 0; i < manifest.length; i++) {
        final item = manifest[i];
        if (item['size'] != publicFiles[i]['size'] || item['size'] is! int || (item['sha256'] as String? ?? '').length != 64) throw Exception('Invalid file manifest');
        item['relativePath'] = _safePath(item['relativePath'] as String? ?? item['name'] as String? ?? 'file');
      }
      final paths = manifest.map((item) => item['relativePath'] as String).toSet();
      if (paths.length != manifest.length) throw Exception('Duplicate file paths in manifest');
      final rootDir = await getApplicationDocumentsDirectory();
      final root = p.join(rootDir.path, 'QuickSend', 'Received', id);
      await Directory(root).create(recursive: true);
      for (final item in manifest) {
        final target = p.joinAll([root, ...p.posix.split(item['relativePath'] as String)]);
        await Directory(p.dirname(target)).create(recursive: true);
        await File(target).create(recursive: true);
      }
      _receivers[id] = _Receiving(SecretKey(keyBytes), manifest, root);
      final progress = TransferProgress(id: id, label: '${manifest.length} file${manifest.length == 1 ? '' : 's'}', totalBytes: manifest.fold<int>(0, (sum, file) => sum + (file['size'] as int)), peerLabel: sender.name, state: TransferState.running);
      transfers.insert(0, progress);
      notifyListeners();
    } catch (e) {
      _send({'type': 'cancel', 'transferId': id}); error = 'Could not prepare incoming transfer: $e'; notifyListeners();
    }
  }

  Future<void> _handleChunk(Uint8List frame) async {
    if (frame.length < 4 + 2 + 12 + 16) return;
    final view = ByteData.sublistView(frame);
    final metaLength = view.getUint32(0, Endian.big);
    if (metaLength > 2048 || 4 + metaLength + 28 > frame.length) throw Exception('Bad chunk header');
    final metadataBytes = frame.sublist(4, 4 + metaLength);
    final metadata = Map<String, dynamic>.from(jsonDecode(utf8.decode(metadataBytes)) as Map);
    final id = metadata['transferId'] as String; final fileIndex = metadata['fileIndex'] as int; final seq = metadata['seq'] as int;
    final receive = _receivers[id]; if (receive == null || fileIndex < 0 || fileIndex >= receive.files.length) return;
    final expected = receive.nextSeq[fileIndex] ?? 0;
    if (seq != expected) throw Exception('Out-of-order chunk');
    final nonceStart = 4 + metaLength; final cipherStart = nonceStart + 12;
    final cipherEnd = frame.length - 16;
    final plain = await _aead.decrypt(SecretBox(frame.sublist(cipherStart, cipherEnd), nonce: frame.sublist(nonceStart, cipherStart), mac: Mac(frame.sublist(cipherEnd))), secretKey: receive.key, aad: metadataBytes);
    final item = receive.files[fileIndex];
    final relative = _safePath(item['relativePath'] as String? ?? item['name'] as String? ?? 'file');
    final target = p.joinAll([receive.root, ...p.posix.split(relative)]);
    if (!p.isWithin(receive.root, target)) throw Exception('Unsafe file path');
    await Directory(p.dirname(target)).create(recursive: true);
    final output = File(target);
    await output.writeAsBytes(plain, mode: FileMode.append, flush: false);
    receive.nextSeq[fileIndex] = expected + 1;
    receive.received[fileIndex] = (receive.received[fileIndex] ?? 0) + plain.length;
    final progress = _findTransfer(id); if (progress != null) progress.received += plain.length;
    _send({'type': 'chunk-ack', 'transferId': id, 'fileIndex': fileIndex, 'seq': seq});
    notifyListeners();
  }

  Future<void> _finishTransfer(String id) async {
    final receive = _receivers.remove(id);
    if (receive != null) {
      try {
        for (final entry in receive.files.asMap().entries) {
          final item = entry.value;
          if ((receive.received[entry.key] ?? 0) != item['size']) throw Exception('File size mismatch for ${item['name']}');
          final target = p.joinAll([receive.root, ...p.posix.split(_safePath(item['relativePath'] as String? ?? item['name'] as String? ?? 'file'))]);
          final hash = await digest.sha256.bind(File(target).openRead()).first;
          if (hash.toString() != item['sha256']) throw Exception('SHA-256 check failed for ${item['name']}');
        }
        savedFiles[id] = receive.files.map((item) => p.joinAll([receive.root, ...p.posix.split(item['relativePath'] as String)])).toList();
        final progress = _findTransfer(id); if (progress != null) progress.state = TransferState.finished;
        _send({'type': 'verified', 'transferId': id, 'ok': true});
      } catch (e) {
        final progress = _findTransfer(id); if (progress != null) progress.state = TransferState.failed;
        error = 'Received file failed integrity verification: $e';
        _send({'type': 'verified', 'transferId': id, 'ok': false});
      }
    } else {
      final progress = _findTransfer(id); if (progress != null) progress.state = TransferState.finished;
      _pendingSend.remove(id);
    }
    notifyListeners();
  }

  TransferProgress? _findTransfer(String id) { for (final item in transfers) { if (item.id == id) return item; } return null; }
  void _send(Map<String, dynamic> message) { if (_channel != null && connection != RoomConnectionState.disconnected) _channel!.sink.add(jsonEncode(message)); }
  void _setDisconnected(String? reason) {
    connection = RoomConnectionState.disconnected; _channel = null; _myId = null; _keyPair = null; _roomSecret = null;
    peers.clear(); groups.clear(); incoming.clear(); groupInvites.clear();
    for (final progress in transfers.where((item) => item.state == TransferState.running || item.state == TransferState.waiting)) { progress.state = TransferState.failed; }
    if (reason != null) error = reason;
    notifyListeners();
  }
  bool _constantTimeEqual(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var i = 0; i < first.length; i++) { difference |= first[i] ^ second[i]; }
    return difference == 0;
  }

  Uint8List _randomBytes(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));
  Uint8List _u32(int value) => (ByteData(4)..setUint32(0, value, Endian.big)).buffer.asUint8List();
  String _uuid() => '${_hex(4)}-${_hex(2)}-4${_hex(2).substring(1)}-${(8 + _random.nextInt(4)).toRadixString(16)}${_hex(2).substring(1)}-${_hex(6)}';
  String _hex(int bytes) => List.generate(bytes, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  String _safePath(String value) {
    final normalized = value.replaceAll('\\', '/');
    final parts = p.posix.normalize(normalized).split('/').where((part) => part.isNotEmpty && part != '.' && part != '..' && !part.contains(':')).map((part) => part.replaceAll(RegExp(r'[\x00-\x1f]'), '_')).toList();
    return parts.isEmpty ? 'file' : parts.join('/');
  }

  @override
  void dispose() { _subscription?.cancel(); _channel?.sink.close(); _relayHost.stop(); super.dispose(); }
}
