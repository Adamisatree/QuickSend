import 'package:flutter_test/flutter_test.dart';
import 'package:quicksend_native/src/models.dart';

void main() {
  group('device and group models', () {
    test('peer reads only identity fields and optional authentication tag', () {
      final peer = Peer.fromJson({'id': 'peer-1', 'name': 'Laptop', 'ip': '192.168.1.2', 'publicKey': 'abc', 'auth': 'tag'});
      expect(peer.name, 'Laptop');
      expect(peer.ip, '192.168.1.2');
      expect(peer.auth, 'tag');
      expect(Peer.fromJson({}).name, 'QuickSend');
    });

    test('group parses members and messages without sharing mutable lists', () {
      final group = ChatGroup.fromJson({
        'id': 'g1', 'name': 'Family', 'ownerId': 'p1',
        'members': [{'id': 'p1', 'name': 'Phone', 'ip': '10.0.0.2', 'publicKey': 'key'}],
        'messages': [{'id': 'm1', 'groupId': 'g1', 'senderId': 'p1', 'text': 'hello', 'createdAt': '2026-01-01T00:00:00Z'}],
      });
      expect(group.name, 'Family');
      expect(group.members.single.name, 'Phone');
      expect(group.messages.single.text, 'hello');
      expect(group.messages.single.createdAt.isUtc, isTrue);
    });
  });

  test('transfer progress is clamped and handles empty files', () {
    final transfer = TransferProgress(id: 'x', label: 'file', totalBytes: 100);
    expect(transfer.fraction, 0);
    transfer.received = 40;
    expect(transfer.fraction, .4);
    transfer.received = 120;
    expect(transfer.fraction, 1);
    expect(TransferProgress(id: 'z', label: 'empty', totalBytes: 0).fraction, 1);
  });
}
