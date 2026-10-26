import 'package:flutter_test/flutter_test.dart';
import 'package:quicksend_native/src/transfer_safety.dart';

void main() {
  group('protocol identifiers', () {
    test('accepts generated UUID v4 identifiers only', () {
      expect(isValidUuidV4('d9428888-122b-4a51-8b4d-1234567890ab'), isTrue);
      expect(isValidUuidV4('../outside'), isFalse);
      expect(isValidUuidV4('d9428888-122b-1a51-8b4d-1234567890ab'), isFalse);
    });

    test('validates SHA-256 as exactly 64 hex characters', () {
      expect(isValidSha256(List.filled(64, 'a').join()), isTrue);
      expect(isValidSha256(List.filled(64, 'g').join()), isFalse);
      expect(isValidSha256(List.filled(63, 'a').join()), isFalse);
    });
  });

  group('cross-platform file paths', () {
    test('accepts nested relative paths and normalizes Windows separators', () {
      expect(validateRelativePath(r'photos\2026\image.jpg'), 'photos/2026/image.jpg');
      expect(validateRelativePath('notes.txt'), 'notes.txt');
    });

    test('rejects traversal, absolute, and drive paths', () {
      for (final value in ['../outside.txt', r'folder\..\outside.txt', '/etc/passwd', r'C:\Windows\system.ini', r'\\server\share\file']) {
        expect(() => validateRelativePath(value), throwsFormatException, reason: value);
      }
    });

    test('rejects ambiguous platform-specific names', () {
      for (final value in ['folder//file', 'folder/./file', 'folder/../file', 'CON', 'aux.txt', 'trailing.', 'trailing ', 'bad:name', 'bad\u0000name']) {
        expect(() => validateRelativePath(value), throwsFormatException, reason: value);
      }
    });
  });
}
