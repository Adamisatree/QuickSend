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
import 'lan_discovery.dart';
import 'relay_host.dart';
import 'transfer_safety.dart';

class IncomingRequest {
  const IncomingRequest({required this.transferId, required this.senderName, required this.senderIp, required this.fileCount, required this.totalBytes, required this.mode});
  final String transferId;
  final String senderName;
  final String senderIp;
  final TransferMode mode;
  final int fileCount;
  final int totalBytes;
}

class GroupInvite {
  const GroupInvite({required this.group, required this.inviter});
  final ChatGroup group;
  final Peer inviter;
}

class _Receiving {
  _Receiving({required this.key, required this.strict, required this.files, required this.root});
  final SecretKey? key;
  final bool strict;
  final List<Map<String, dynamic>> files;
  final String root;
  final Map<int, int> nextSeq = {};
  final Map<int, int> received = {};
}

class ClientController extends ChangeNotifier {
  ClientController() : _relayHost = RelayHost() {
    _discovery = LanDiscovery(onDevicesChanged: (devices) { discoveredDevices = devices; notifyListeners(); });
  }
  RelayHost _relayHost;
  late final LanDiscovery _discovery;
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
  List<LanDevice> discoveredDevices = const [];
  String? discoveryWarning;
  RoomConnectionState connection = RoomConnectionState.disconnected;
  String? error;
  final Map<String, Peer> peers = {};
  final Map<String, ChatGroup> groups = {};
  final Map<String, IncomingRequest> incoming = {};
  final Map<String, GroupInvite> groupInvites = {};
  final Map<String, _Receiving> _receivers = {};
  final Map<String, Completer<void>> _acks = {};
  final Set<Completer<void>> _activeAcks = {};
  final Map<String, Map<String, dynamic>> _pendingSend = {};
  final Set<String> _abortedTransfers = {};
  final List<TransferProgress> transfers = [];
  final Map<String, List<String>> savedFiles = {};
  Future<void> _binaryQueue = Future<void>.value();
  bool get hosting => _relayHost.isRunning;
  int get hostPort => _relayHost.boundPort;
  String get endpoint => _endpoint;
  String? get myId => _myId;

  Future<void> startDiscovery() async {
    try {
      await _discovery.start();
      _discovery.scan();
      discoveryWarning = null;
    } catch (_) {
      discoveryWarning = '自动发现不可用，请手动输入设备 IP。';
    }
    notifyListeners();
  }

  void setDeviceName(String value) {
    final clean = value.trim();
    if (clean.isEmpty) return;
    _name = clean.substring(0, min(clean.length, 32));
    _discovery.updatePresence(name: _name, relayPort: hosting ? hostPort : null);
  }

  Future<void> startHosting({int port = 4321}) async {
    try {
      if (_relayHost.port != port) _relayHost = RelayHost(port: port);
      await _relayHost.start();
      final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      localAddresses = interfaces.expand((interface) => interface.addresses).where((address) => !address.isLoopback).map((address) => address.address).toSet().toList();
      _discovery.updatePresence(name: _name, relayPort: _relayHost.boundPort);
      error = null;
    }
    catch (e) { error = '无法在端口 $port 启动局域网中继：$e'; }
    notifyListeners();
  }

  Future<void> stopHosting() async {
    _discovery.updatePresence(name: _name, relayPort: null);
    await _relayHost.stop();
    if (_channel != null) await disconnect();
    notifyListeners();
  }

  Future<void> connect({required String host, required int port, required String roomKey, required String name}) async {
    await disconnect();
    final cleanKey = roomKey.trim();
    if (cleanKey.length < 12) { error = '房间密钥至少需要 12 个字符，建议使用随机短语。'; notifyListeners(); return; }
    if (cleanKey.length > 256) { error = '房间密钥过长。'; notifyListeners(); return; }
    final address = InternetAddress.tryParse(host.trim());
    if (address == null || address.type != InternetAddressType.IPv4) { error = '请输入同一局域网内有效的 IPv4 地址。'; notifyListeners(); return; }
    if (port < 1 || port > 65535) { error = '端口范围必须为 1 到 65535。'; notifyListeners(); return; }
    connection = RoomConnectionState.connecting; error = null; notifyListeners();
    try {
      _name = name.trim().isEmpty ? 'QuickSend' : name.trim().substring(0, min(name.trim().length, 32));
      _discovery.updatePresence(name: _name, relayPort: hosting ? hostPort : null);
      _roomHash = digest.sha256.convert(utf8.encode(cleanKey)).toString();
      _roomSecret = await _hkdf.deriveKey(secretKey: SecretKey(utf8.encode(cleanKey)), nonce: Uint8List(16), info: utf8.encode('QuickSend v2 room authentication'));
      _keyPair = await _x25519.newKeyPair();
      final channel = WebSocketChannel.connect(Uri(scheme: 'ws', host: address.address, port: port, path: '/ws'));
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 8));
      _subscription = channel.stream.listen(_onSocketData, onError: (Object e) { _setDisconnected('连接错误：$e'); }, onDone: () { _setDisconnected(null); });
      // The relay first assigns an opaque connection ID; the signed hello follows the challenge.
      _endpoint = '${address.address}:$port';
    } catch (e) {
      _setDisconnected('连接失败：$e');
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _subscription?.cancel(); _subscription = null;
    await _channel?.sink.close(); _channel = null;
    connection = RoomConnectionState.disconnected; _myId = null; _roomSecret = null; _keyPair = null;
    peers.clear(); groups.clear(); incoming.clear(); groupInvites.clear();
    _clearTransientTransfers();
    notifyListeners();
  }

  void setName(String value) {
    final clean = value.trim(); if (clean.isEmpty) return;
    _name = clean.substring(0, min(clean.length, 32));
    _discovery.updatePresence(name: _name, relayPort: hosting ? hostPort : null);
    _send({'type': 'rename', 'name': _name});
  }

  Future<void> createGroup(String name, Iterable<String> memberIds) async => _send({'type': 'group-create', 'name': name, 'members': memberIds.toList()});
  Future<void> respondGroupInvite(String groupId, bool accept) async {
    groupInvites.remove(groupId);
    if (accept) {
      _send({'type': 'group-join', 'groupId': groupId});
    } else {
      _send({'type': 'group-decline', 'groupId': groupId});
    }
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

  Future<void> sendFiles({required List<SharedFile> files, required Iterable<String> recipientIds, TransferMode mode = TransferMode.strict}) async {
    if (connection != RoomConnectionState.connected || _myId == null || _keyPair == null) { error = '发送前请先连接房间。'; notifyListeners(); return; }
    final ids = recipientIds.toSet();
    if (files.isEmpty || ids.isEmpty) { error = '请至少选择一个文件和一台接收设备。'; notifyListeners(); return; }
    if (files.length > maxTransferFiles || files.any((file) => file.size < 0 || file.size > maxFileBytes) || files.fold<int>(0, (sum, file) => sum + file.size) > maxTransferBytes) { error = '文件数量或大小超过安全限制。'; notifyListeners(); return; }
    try {
      final manifests = <Map<String, dynamic>>[];
      final uniquePaths = <String>{};
      for (final item in files) {
        final relativePath = validateRelativePath(item.relativePath);
        if (!uniquePaths.add(relativePath.toLowerCase())) throw Exception('文件路径重复：$relativePath');
        final file = File(item.path);
        if (!await file.exists()) throw Exception('文件已不存在：${item.name}');
        final actualSize = await file.length();
        if (actualSize != item.size || actualSize > maxFileBytes) throw Exception('文件已更改或超过单文件大小限制：${item.name}');
        final hash = await digest.sha256.bind(file.openRead()).first;
        manifests.add({'name': item.name, 'relativePath': relativePath, 'size': actualSize, 'sha256': hash.toString(), 'type': 'application/octet-stream'});
      }
      final transferId = _uuid();
      final strict = mode == TransferMode.strict;
      final transferKeyBytes = strict ? _randomBytes(32) : null;
      final transferKey = transferKeyBytes == null ? null : SecretKey(transferKeyBytes);
      final envelopes = <String, dynamic>{};
      for (final recipientId in ids) {
        final peer = peers[recipientId];
        if (peer == null || !await _verifyPeer(peer)) throw Exception('无法验证设备身份（${peer?.name ?? recipientId}），请重新连接私密房间。');
        if (!strict) continue;
        final shared = await _x25519.sharedSecretKey(keyPair: _keyPair!, remotePublicKey: SimplePublicKey(base64.decode(peer.publicKey), type: KeyPairType.x25519));
        final wrappingKey = await _hkdf.deriveKey(secretKey: shared, nonce: utf8.encode(transferId), info: utf8.encode('QuickSend v2 key wrap|${peer.id}'));
        final nonce = _randomBytes(12);
        final payload = utf8.encode(jsonEncode({'key': base64.encode(transferKeyBytes!), 'files': manifests}));
        final box = await _aead.encrypt(payload, secretKey: wrappingKey, nonce: nonce, aad: utf8.encode('QuickSend v2 manifest|$transferId|${peer.id}'));
        envelopes[peer.id] = {'nonce': base64.encode(nonce), 'ciphertext': base64.encode([...box.cipherText, ...box.mac.bytes])};
      }
      final total = manifests.fold<int>(0, (sum, file) => sum + (file['size'] as int));
      final progress = TransferProgress(id: transferId, label: '${files.length} file${files.length == 1 ? '' : 's'}', totalBytes: total, peerLabel: ids.map((id) => peers[id]?.name ?? '?').join(', '));
      transfers.insert(0, progress);
      _abortedTransfers.remove(transferId);
      _pendingSend[transferId] = {'files': files, 'key': transferKey, 'strict': strict, 'progress': progress};
      final relayFiles = strict
          ? manifests.map((f) => {'size': f['size']}).toList()
          : manifests.map((f) => {'name': f['name'], 'relativePath': f['relativePath'], 'size': f['size'], 'sha256': f['sha256']}).toList();
      _send({'type': 'request-transfer', 'transferId': transferId, 'recipients': ids.toList(), 'mode': strict ? 'strict' : 'speed', 'files': relayFiles, 'keyEnvelopes': envelopes});
      error = null; notifyListeners();
    } catch (e) { error = '无法准备传输：$e'; notifyListeners(); }
  }

  Future<void> decideIncoming(String id, bool accept) async {
    final request = incoming.remove(id);
    _send({'type': 'decision', 'transferId': id, 'accept': accept});
    notifyListeners();
    if (request == null || !accept) return;
  }

  Future<void> cancelTransfer(String id) async {
    _abortTransfer(id);
    final progress = _findTransfer(id);
    if (progress != null && progress.state != TransferState.finished) progress.state = TransferState.failed;
    _send({'type': 'cancel', 'transferId': id});
    notifyListeners();
  }
  void clearError() { error = null; notifyListeners(); }

  void _onSocketData(dynamic raw) {
    if (raw is List<int>) {
      if (raw.length > maxChunkBytes + 2048 + 32) {
        _setDisconnected('中继数据块超过安全限制。');
        return;
      }
      final bytes = Uint8List.fromList(raw);
      _binaryQueue = _binaryQueue.then((_) => _handleChunk(bytes)).catchError((Object e) { error = '无法接收数据块：$e'; notifyListeners(); });
      return;
    }
    if (raw is! String) return;
    if (utf8.encode(raw).length > 8 * 1024 * 1024) {
      _setDisconnected('中继消息超过安全限制。');
      return;
    }
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
              if (!valid) { _send({'type': 'decision', 'transferId': id, 'accept': false}); error = '已拒绝身份验证失败的文件传输。'; }
              else { incoming[id] = IncomingRequest(transferId: id, senderName: sender.name, senderIp: sender.ip, fileCount: files.length, totalBytes: files.fold<int>(0, (sum, file) => sum + ((file['size'] as num?)?.toInt() ?? 0)), mode: message['mode'] == 'speed' ? TransferMode.speed : TransferMode.strict); }
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
          final ack = _acks.remove(key);
          if (ack != null) {
            _activeAcks.remove(ack);
            if (!ack.isCompleted) ack.complete();
          }
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
          _abortTransfer(id);
          error = message['message'] as String? ?? '传输失败';
          break;
        case 'error': error = message['message'] as String? ?? '中继错误'; break;
        case 'pong': break;
      }
      notifyListeners();
    } catch (e) { error = '中继消息无效：$e'; notifyListeners(); }
  }

  Future<void> _sendAuthenticatedHello(String id) async {
    try {
      if (id.isEmpty || _keyPair == null || _roomSecret == null) throw Exception('缺少握手挑战或会话密钥');
      final publicKey = await _keyPair!.extractPublicKey();
      final publicText = base64.encode(publicKey.bytes);
      final mac = await Hmac.sha256().calculateMac(utf8.encode('$id|$publicText'), secretKey: _roomSecret!);
      _channel?.sink.add(jsonEncode({'type': 'hello', 'id': id, 'name': _name, 'roomHash': _roomHash, 'publicKey': publicText, 'auth': base64.encode(mac.bytes)}));
    } catch (e) { _setDisconnected('无法验证房间：$e'); }
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
    } catch (_) { error = '加密群聊消息验证失败。'; notifyListeners(); }
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
    final strict = data['strict'] as bool;
    final key = data['key'] as SecretKey?;
    if (strict && key == null) return;
    final progress = data['progress'] as TransferProgress..state = TransferState.running;
    final window = <String>[];
    try {
      for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
        final source = await File(files[fileIndex].path).open(mode: FileMode.read);
        var seq = 0;
        try {
          while (true) {
            if (_abortedTransfers.contains(id) || connection != RoomConnectionState.connected || _channel == null) throw StateError('Transfer cancelled or connection closed');
            final bytes = await source.read(maxChunkBytes);
            if (bytes.isEmpty) break;
            final ackKey = '$id:$fileIndex:$seq';
            final ack = Completer<void>();
            _acks[ackKey] = ack;
            _activeAcks.add(ack);
            window.add(ackKey);
            final metadata = utf8.encode(jsonEncode({'transferId': id, 'fileIndex': fileIndex, 'seq': seq, 'mode': strict ? 'strict' : 'speed'}));
            final frame = BytesBuilder(copy: false)..add(_u32(metadata.length))..add(metadata);
            if (strict) {
              final nonce = _randomBytes(12);
              final box = await _aead.encrypt(bytes, secretKey: key!, nonce: nonce, aad: metadata);
              frame..add(nonce)..add(box.cipherText)..add(box.mac.bytes);
            } else {
              frame.add(bytes);
            }
            if (_abortedTransfers.contains(id) || connection != RoomConnectionState.connected || _channel == null) throw StateError('Transfer cancelled or connection closed');
            _channel!.sink.add(frame.takeBytes());
            progress.received += bytes.length; seq++;
            if (window.length >= 8) await _waitForChunkAck(window.removeAt(0));
            notifyListeners();
          }
        } finally { await source.close(); }
        for (final ackKey in window.toList()) { await _waitForChunkAck(ackKey); window.remove(ackKey); }
      }
      if (_abortedTransfers.contains(id)) throw StateError('Transfer cancelled');
      _send({'type': 'complete', 'transferId': id});
    } catch (e) {
      progress.state = TransferState.failed;
      _abortTransfer(id);
      _send({'type': 'cancel', 'transferId': id});
      error = '传输失败：$e';
    }
    notifyListeners();
  }

  Future<void> _removePartialFiles(_Receiving receive) async {
    try {
      final directory = Directory(receive.root);
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {
      // A failed cleanup must not hide the original transfer error.
    }
  }

  void _abortTransfer(String id) {
    _abortedTransfers.add(id);
    _pendingSend.remove(id);
    final receiving = _receivers.remove(id);
    if (receiving != null) unawaited(_removePartialFiles(receiving));
    final prefix = '$id:';
    for (final entry in _acks.entries.where((entry) => entry.key.startsWith(prefix)).toList()) {
      _acks.remove(entry.key);
      _activeAcks.remove(entry.value);
      if (!entry.value.isCompleted) entry.value.complete();
    }
  }

  Future<void> _waitForChunkAck(String key) async {
    final ack = _acks[key];
    if (ack == null) return; // It may have arrived before the sender reached this window boundary.
    try {
      await ack.future.timeout(const Duration(seconds: 90));
    } finally {
      _acks.remove(key);
      _activeAcks.remove(ack);
    }
  }

  Future<void> _startReceiving(Map<String, dynamic> message) async {
    final id = message['transferId'] as String? ?? '';
    String? stagingRoot;
    try {
      if (!isValidUuidV4(id)) throw Exception('传输编号无效');
      if (_roomSecret == null || _keyPair == null || _myId == null) throw Exception('尚未连接');
      final sender = Peer.fromJson(Map<String, dynamic>.from(message['sender'] as Map));
      if (!await _verifyPeer(sender)) throw Exception('发送方身份验证失败');
      final modeText = message['mode'] as String? ?? 'strict'; // Older relays default to strict mode.
      if (modeText != 'strict' && modeText != 'speed') throw Exception('不支持的传输模式');
      final strict = modeText == 'strict';
      List<Map<String, dynamic>> manifest;
      List<Map<String, dynamic>> publicFiles;
      SecretKey? transferKey;
      if (strict) {
        final envelope = Map<String, dynamic>.from(message['keyEnvelope'] as Map);
        final shared = await _x25519.sharedSecretKey(keyPair: _keyPair!, remotePublicKey: SimplePublicKey(base64.decode(sender.publicKey), type: KeyPairType.x25519));
        final wrappingKey = await _hkdf.deriveKey(secretKey: shared, nonce: utf8.encode(id), info: utf8.encode('QuickSend v2 key wrap|$_myId'));
        final combined = base64.decode(envelope['ciphertext'] as String);
        if (combined.length < 16) throw Exception('加密文件清单无效');
        final plain = await _aead.decrypt(SecretBox(combined.sublist(0, combined.length - 16), nonce: base64.decode(envelope['nonce'] as String), mac: Mac(combined.sublist(combined.length - 16))), secretKey: wrappingKey, aad: utf8.encode('QuickSend v2 manifest|$id|$_myId'));
        final payload = Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map);
        final keyBytes = base64.decode(payload['key'] as String);
        manifest = (payload['files'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        publicFiles = (message['files'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        if (keyBytes.length != 32) throw Exception('传输密钥无效');
        transferKey = SecretKey(keyBytes);
      } else {
        manifest = (message['files'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        publicFiles = manifest;
      }
      if (manifest.isEmpty || manifest.length != publicFiles.length || manifest.length > maxTransferFiles) throw Exception('文件清单不匹配');
      var totalSize = 0;
      final paths = <String>{};
      for (var i = 0; i < manifest.length; i++) {
        final item = manifest[i];
        final size = item['size'];
        final sha256 = item['sha256'];
        if (size is! int || size < 0 || size > maxFileBytes || size != publicFiles[i]['size'] || !isValidSha256(sha256 is String ? sha256 : '')) throw Exception('文件清单无效');
        totalSize += size;
        if (totalSize > maxTransferBytes) throw Exception('传输内容超过安全限制');
        final path = validateRelativePath(item['relativePath'] as String? ?? item['name'] as String? ?? 'file');
        if (!paths.add(path.toLowerCase())) throw Exception('文件清单包含重复或冲突的路径');
        item['relativePath'] = path;
      }
      final rootDir = await getApplicationDocumentsDirectory();
      final rootParent = Directory(p.join(rootDir.path, 'QuickSend', 'Received'));
      await rootParent.create(recursive: true);
      final root = p.join(rootParent.path, id);
      if (await FileSystemEntity.type(root, followLinks: false) != FileSystemEntityType.notFound) throw Exception('接收目录已存在');
      await Directory(root).create();
      stagingRoot = root;
      if (await FileSystemEntity.type(root, followLinks: false) != FileSystemEntityType.directory) throw Exception('接收目录无效');
      for (final item in manifest) {
        final target = p.joinAll([root, ...p.posix.split(item['relativePath'] as String)]);
        if (!p.isWithin(root, target)) throw Exception('文件路径不安全');
        await Directory(p.dirname(target)).create(recursive: true);
        await File(target).create(exclusive: true);
      }
      _receivers[id] = _Receiving(key: transferKey, strict: strict, files: manifest, root: root);
      stagingRoot = null;
      final progress = TransferProgress(id: id, label: '${manifest.length} file${manifest.length == 1 ? '' : 's'}', totalBytes: manifest.fold<int>(0, (sum, file) => sum + (file['size'] as int)), peerLabel: sender.name, state: TransferState.running);
      transfers.insert(0, progress);
      notifyListeners();
    } catch (e) {
      if (stagingRoot != null) {
        try { await Directory(stagingRoot).delete(recursive: true); } catch (_) { }
      }
      _send({'type': 'cancel', 'transferId': id}); error = '无法准备接收文件：$e'; notifyListeners();
    }
  }

  Future<void> _handleChunk(Uint8List frame) async {
    if (frame.length < 5 || frame.length > maxChunkBytes + 2048 + 32) throw Exception('数据块长度超出允许范围');
    final view = ByteData.sublistView(frame);
    final metaLength = view.getUint32(0, Endian.big);
    if (metaLength > 2048 || 4 + metaLength >= frame.length) throw Exception('数据块头无效');
    final metadataBytes = frame.sublist(4, 4 + metaLength);
    final metadata = Map<String, dynamic>.from(jsonDecode(utf8.decode(metadataBytes)) as Map);
    final rawId = metadata['transferId']; final rawFileIndex = metadata['fileIndex']; final rawSeq = metadata['seq'];
    if (rawId is! String || !isValidUuidV4(rawId) || rawFileIndex is! int || rawSeq is! int || rawFileIndex < 0 || rawSeq < 0) throw Exception('数据块元数据无效');
    final id = rawId; final fileIndex = rawFileIndex; final seq = rawSeq;
    final receive = _receivers[id]; if (receive == null || fileIndex >= receive.files.length) return;
    if (metadata['mode'] != (receive.strict ? 'strict' : 'speed')) throw Exception('数据块模式与已批准的传输不一致');
    final overhead = receive.strict ? 28 : 0;
    if (4 + metaLength + overhead >= frame.length) throw Exception('数据块内容为空或格式错误');
    final payloadLength = frame.length - (4 + metaLength + overhead);
    if (payloadLength <= 0 || payloadLength > maxChunkBytes) throw Exception('数据块超过允许大小');
    final expected = receive.nextSeq[fileIndex] ?? 0;
    if (seq != expected) throw Exception('数据块顺序错误');
    final payloadStart = 4 + metaLength;
    final plain = receive.strict
        ? await _aead.decrypt(SecretBox(frame.sublist(payloadStart + 12, frame.length - 16), nonce: frame.sublist(payloadStart, payloadStart + 12), mac: Mac(frame.sublist(frame.length - 16))), secretKey: receive.key!, aad: metadataBytes)
        : Uint8List.sublistView(frame, payloadStart);
    if (plain.isEmpty || plain.length > maxChunkBytes) throw Exception('明文数据块大小无效');
    final item = receive.files[fileIndex];
    final receivedForFile = receive.received[fileIndex] ?? 0;
    if (receivedForFile + plain.length > (item['size'] as int)) throw Exception('数据块超过声明的文件大小');
    final relative = validateRelativePath(item['relativePath'] as String? ?? item['name'] as String? ?? 'file');
    final target = p.joinAll([receive.root, ...p.posix.split(relative)]);
    if (!p.isWithin(receive.root, target)) throw Exception('文件路径不安全');
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
          if ((receive.received[entry.key] ?? 0) != item['size']) throw Exception('文件大小不匹配：${item['name']}');
          final target = p.joinAll([receive.root, ...p.posix.split(_safePath(item['relativePath'] as String? ?? item['name'] as String? ?? 'file'))]);
          final hash = await digest.sha256.bind(File(target).openRead()).first;
          if (hash.toString() != item['sha256']) throw Exception('SHA-256 校验失败：${item['name']}');
        }
        savedFiles[id] = receive.files.map((item) => p.joinAll([receive.root, ...p.posix.split(item['relativePath'] as String)])).toList();
        final progress = _findTransfer(id); if (progress != null) progress.state = TransferState.finished;
        _send({'type': 'verified', 'transferId': id, 'ok': true});
      } catch (e) {
        final progress = _findTransfer(id); if (progress != null) progress.state = TransferState.failed;
        await _removePartialFiles(receive);
        error = '收到的文件完整性校验失败：$e';
        _send({'type': 'verified', 'transferId': id, 'ok': false});
      }
    } else {
      final progress = _findTransfer(id); if (progress != null) progress.state = TransferState.finished;
      _pendingSend.remove(id);
    }
    _abortedTransfers.remove(id);
    notifyListeners();
  }

  TransferProgress? _findTransfer(String id) { for (final item in transfers) { if (item.id == id) return item; } return null; }
  void _send(Map<String, dynamic> message) { if (_channel != null && connection != RoomConnectionState.disconnected) _channel!.sink.add(jsonEncode(message)); }
  void _clearTransientTransfers() {
    for (final progress in transfers.where((item) => item.state == TransferState.running || item.state == TransferState.waiting)) {
      progress.state = TransferState.failed;
    }
    for (final ack in _activeAcks.toList()) {
      if (!ack.isCompleted) ack.complete();
    }
    _activeAcks.clear();
    _acks.clear();
    _pendingSend.clear();
    for (final receive in _receivers.values) {
      unawaited(_removePartialFiles(receive));
    }
    _receivers.clear();
    _abortedTransfers.clear();
  }

  void _setDisconnected(String? reason) {
    connection = RoomConnectionState.disconnected; _channel = null; _myId = null; _keyPair = null; _roomSecret = null;
    peers.clear(); groups.clear(); incoming.clear(); groupInvites.clear();
    _clearTransientTransfers();
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
  String _safePath(String value) => validateRelativePath(value);

  @override
  void dispose() { _subscription?.cancel(); _channel?.sink.close(); _discovery.dispose(); _relayHost.stop(); super.dispose(); }
}
