class Peer {
  const Peer({required this.id, required this.name, required this.ip, required this.publicKey, this.auth = ''});
  final String id;
  final String name;
  final String ip;
  final String publicKey;
  factory Peer.fromJson(Map<String, dynamic> json) => Peer(
    id: json['id'] as String? ?? '', name: json['name'] as String? ?? 'QuickSend',
    ip: json['ip'] as String? ?? '—', publicKey: json['publicKey'] as String? ?? '', auth: json['auth'] as String? ?? '',
  );
}

class SharedFile {
  const SharedFile({required this.path, required this.name, required this.relativePath, required this.size});
  final String path;
  final String name;
  final String relativePath;
  final int size;
  Map<String, dynamic> toJson(String digest) => {
    'name': name, 'relativePath': relativePath, 'size': size, 'type': 'application/octet-stream', 'sha256': digest,
  };
}

class ChatMessage {
  const ChatMessage({required this.id, required this.groupId, required this.senderId, required this.senderName, required this.senderIp, required this.text, required this.createdAt});
  final String id;
  final String groupId;
  final String senderId;
  final String senderName;
  final String senderIp;
  final String text;
  final DateTime createdAt;
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String? ?? '', groupId: json['groupId'] as String? ?? '',
    senderId: json['senderId'] as String? ?? '', senderName: json['senderName'] as String? ?? '',
    senderIp: json['senderIp'] as String? ?? '', text: json['text'] as String? ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}

class ChatGroup {
  const ChatGroup({required this.id, required this.name, required this.ownerId, required this.members, required this.messages});
  final String id;
  final String name;
  final String ownerId;
  final List<Peer> members;
  final List<ChatMessage> messages;
  factory ChatGroup.fromJson(Map<String, dynamic> json) => ChatGroup(
    id: json['id'] as String? ?? '', name: json['name'] as String? ?? '群聊',
    ownerId: json['ownerId'] as String? ?? '',
    members: ((json['members'] as List?) ?? const []).map((e) => Peer.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
    messages: ((json['messages'] as List?) ?? const []).map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
  );
}

class TransferProgress {
  TransferProgress({required this.id, required this.label, required this.totalBytes, this.peerLabel = '', this.received = 0, this.state = TransferState.waiting});
  final String id;
  final String label;
  final int totalBytes;
  final String peerLabel;
  int received;
  TransferState state;
  double get fraction => totalBytes == 0 ? 1 : (received / totalBytes).clamp(0, 1);
}

enum TransferState { waiting, running, finished, failed }
enum RoomConnectionState { disconnected, connecting, connected }
