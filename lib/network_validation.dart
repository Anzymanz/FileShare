import 'dart:typed_data';

bool isValidRemoteFileName(String name, {int maxChars = 260}) {
  if (name.trim().isEmpty || name.length > maxChars) return false;
  if (RegExp(r'[\x00-\x1F]').hasMatch(name)) return false;
  if (RegExp(r'[<>:"/\\|?*]').hasMatch(name)) return false;
  return !isReservedWindowsName(name);
}

bool isValidRelativePath(String rel, {int maxChars = 1024}) {
  if (rel.trim().isEmpty || rel.length > maxChars) return false;
  if (RegExp(r'[\x00-\x1F]').hasMatch(rel)) return false;
  final normalized = rel.replaceAll('\\', '/');
  if (normalized.startsWith('/') || normalized.contains('//')) return false;
  if (normalized.split('/').any((segment) {
    final s = segment.trim();
    if (s.isEmpty || s == '.' || s == '..') return true;
    return isReservedWindowsName(s);
  })) {
    return false;
  }
  return true;
}

bool isReservedWindowsName(String name) {
  final base = name.split('.').first.trim().toUpperCase();
  if (base.isEmpty) return true;
  const reserved = <String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  return reserved.contains(base);
}

int fastBytesFingerprint(Uint8List bytes) {
  var hash = 0x811C9DC5;
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  hash ^= bytes.length;
  return hash & 0x7FFFFFFF;
}
