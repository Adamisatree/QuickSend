const maxTransferFiles = 100;
const maxFileBytes = 100 * 1024 * 1024 * 1024;
const maxTransferBytes = 500 * 1024 * 1024 * 1024;
const maxChunkBytes = 256 * 1024;

final RegExp _transferIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
final RegExp _drivePrefix = RegExp(r'^[a-z]:', caseSensitive: false);
final RegExp _controlCharacter = RegExp(r'[\x00-\x1f\x7f]');
final RegExp _windowsReservedName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$',
  caseSensitive: false,
);

bool isValidUuidV4(String value) => _transferIdPattern.hasMatch(value);
bool isValidSha256(String value) => _sha256Pattern.hasMatch(value);

/// Validates a cross-platform relative path without silently rewriting it.
/// Rejecting ambiguous names avoids traversal, collisions, and Windows device paths.
String validateRelativePath(String value) {
  if (value.isEmpty || value.length > 1024 || _controlCharacter.hasMatch(value)) {
    throw const FormatException('Invalid file path length or control character');
  }
  final path = value.replaceAll('\\', '/');
  if (path.startsWith('/') || path.startsWith('//') || _drivePrefix.hasMatch(path)) {
    throw const FormatException('Absolute paths are not allowed');
  }
  final segments = path.split('/');
  if (segments.isEmpty || segments.length > 64) {
    throw const FormatException('Invalid path depth');
  }
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.' || segment == '..') {
      throw const FormatException('Invalid path segment');
    }
    if (segment.length > 255 ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        segment.contains(RegExp(r'[<>:"|?*]')) ||
        _windowsReservedName.hasMatch(segment)) {
      throw const FormatException('Path contains a non-portable file name');
    }
  }
  return segments.join('/');
}
