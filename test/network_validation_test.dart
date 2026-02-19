import 'dart:typed_data';

import 'package:fileshare/network_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isReservedWindowsName', () {
    test('detects reserved names', () {
      expect(isReservedWindowsName('CON'), isTrue);
      expect(isReservedWindowsName('nul.txt'), isTrue);
      expect(isReservedWindowsName('COM1.log'), isTrue);
    });

    test('allows normal names', () {
      expect(isReservedWindowsName('report.txt'), isFalse);
      expect(isReservedWindowsName('photos'), isFalse);
    });
  });

  group('isValidRemoteFileName', () {
    test('rejects invalid characters and control chars', () {
      expect(isValidRemoteFileName('a<b.txt'), isFalse);
      expect(isValidRemoteFileName('bad\x01name.txt'), isFalse);
      expect(isValidRemoteFileName('CON'), isFalse);
    });

    test('accepts valid names', () {
      expect(isValidRemoteFileName('sample.txt'), isTrue);
      expect(isValidRemoteFileName('team_notes-2026.md'), isTrue);
    });
  });

  group('isValidRelativePath', () {
    test('rejects traversal and absolute-like paths', () {
      expect(isValidRelativePath('../secret.txt'), isFalse);
      expect(isValidRelativePath('/root/file.txt'), isFalse);
      expect(isValidRelativePath('a//b.txt'), isFalse);
      expect(isValidRelativePath('docs/CON/readme.md'), isFalse);
    });

    test('accepts normal relative paths', () {
      expect(isValidRelativePath('docs/readme.md'), isTrue);
      expect(isValidRelativePath('folder\\nested\\file.txt'), isTrue);
    });
  });

  group('fastBytesFingerprint', () {
    test('is stable for same bytes and differs for changed bytes', () {
      final a = Uint8List.fromList([1, 2, 3, 4, 5]);
      final b = Uint8List.fromList([1, 2, 3, 4, 5]);
      final c = Uint8List.fromList([1, 2, 3, 4, 6]);

      final fa = fastBytesFingerprint(a);
      final fb = fastBytesFingerprint(b);
      final fc = fastBytesFingerprint(c);

      expect(fa, equals(fb));
      expect(fa, isNot(equals(fc)));
    });
  });
}
