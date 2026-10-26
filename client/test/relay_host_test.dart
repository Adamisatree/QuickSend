import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quicksend_native/src/relay_host.dart';

class _TestPeer {
  _TestPeer(this.socket, this.messages, this.id);
  final WebSocket socket;
  final StreamIterator<dynamic> messages;
  final String id;
}

Future<Map<String, dynamic>> _nextJson(StreamIterator<dynamic> iterator) async {
  while (await iterator.moveNext().timeout(const Duration(seconds: 5))) {
    final value = iterator.current;
    if (value is String) return Map<String, dynamic>.from(jsonDecode(value) as Map);
  }
  throw StateError('Relay closed before sending the expected message');
}

Future<Map<String, dynamic>> _nextType(StreamIterator<dynamic> iterator, String type) async {
  for (var i = 0; i < 20; i++) {
    final message = await _nextJson(iterator);
    if (message['type'] == type) return message;
  }
  throw StateError('Relay did not send $type');
}

Future<_TestPeer> _join(RelayHost relay, List<WebSocket> sockets, String name, int keyByte) async {
  final socket = await WebSocket.connect('ws://127.0.0.1:${relay.boundPort}/ws');
  sockets.add(socket);
  final messages = StreamIterator<dynamic>(socket);
  final challenge = await _nextJson(messages);
  socket.add(jsonEncode({
    'type': 'hello',
    'id': challenge['id'],
    'name': name,
    'roomHash': List.filled(64, 'c').join(),
    'publicKey': base64Encode(List.filled(32, keyByte)),
    'auth': base64Encode(List.filled(32, keyByte + 1)),
  }));
  final welcome = await _nextType(messages, 'welcome');
  return _TestPeer(socket, messages, welcome['id'] as String);
}

void main() {
  late RelayHost relay;
  final sockets = <WebSocket>[];

  setUp(() async {
    relay = RelayHost(port: 0);
    await relay.start();
  });

  tearDown(() async {
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    await relay.stop();
  });

  test('rejects malformed authentication-tag encodings during room join', () async {
    final socket = await WebSocket.connect('ws://127.0.0.1:${relay.boundPort}/ws');
    sockets.add(socket);
    final iterator = StreamIterator<dynamic>(socket);
    final challenge = await _nextJson(iterator);
    expect(challenge['type'], 'challenge');

    socket.add(jsonEncode({
      'type': 'hello',
      'id': challenge['id'],
      'name': 'test',
      'roomHash': List.filled(64, 'a').join(),
      'publicKey': base64Encode(List.filled(32, 1)),
      'auth': 'not-base64',
    }));

    final error = await _nextJson(iterator);
    expect(error['type'], 'error');
    expect(error['message'], 'Invalid room key or public key');
    await iterator.cancel();
  });

  test('rejects non-UUID transfer IDs before storing state', () async {
    final peer = await _join(relay, sockets, 'test', 2);
    await _nextType(peer.messages, 'peers');

    peer.socket.add(jsonEncode({
      'type': 'request-transfer',
      'transferId': '../outside',
      'recipients': ['offline-peer'],
      'files': [{'size': 1}],
      'keyEnvelopes': {},
    }));

    final error = await _nextJson(peer.messages);
    expect(error['type'], 'transfer-error');
    expect(error['message'], 'Invalid transfer manifest');
    await peer.messages.cancel();
  });

  test('does not forward chunks beyond their declared file size', () async {
    final sender = await _join(relay, sockets, 'sender', 4);
    final recipient = await _join(relay, sockets, 'recipient', 6);
    await _nextType(sender.messages, 'peers'); // The second join broadcasts the peer list.
    await _nextType(recipient.messages, 'peers');
    const transferId = 'd9428888-122b-4a51-8b4d-1234567890ab';
    sender.socket.add(jsonEncode({
      'type': 'request-transfer',
      'transferId': transferId,
      'recipients': [recipient.id],
      'files': [{'size': 1}],
      'keyEnvelopes': {
        recipient.id: {'nonce': base64Encode(List.filled(12, 7)), 'ciphertext': base64Encode(List.filled(48, 8))},
      },
    }));
    expect((await _nextType(sender.messages, 'transfer-state'))['state'], 'waiting');
    expect((await _nextType(recipient.messages, 'incoming-request'))['transferId'], transferId);

    recipient.socket.add(jsonEncode({'type': 'decision', 'transferId': transferId, 'accept': true}));
    await _nextType(sender.messages, 'recipient-decision');
    await _nextType(sender.messages, 'transfer-ready');
    await _nextType(recipient.messages, 'transfer-start');

    final metadata = utf8.encode(jsonEncode({'transferId': transferId, 'fileIndex': 0, 'seq': 0}));
    final header = ByteData(4)..setUint32(0, metadata.length, Endian.big);
    sender.socket.add([
      ...header.buffer.asUint8List(),
      ...metadata,
      ...List.filled(12, 0),
      ...List.filled(2 + 16, 0), // Two plaintext bytes plus the AEAD tag; manifest allowed one.
    ]);
    sender.socket.add(jsonEncode({'type': 'complete', 'transferId': transferId}));

    final error = await _nextType(sender.messages, 'transfer-error');
    expect(error['message'], 'Sender ended before all declared file bytes were delivered');
    await sender.messages.cancel();
    await recipient.messages.cancel();
  });
}
