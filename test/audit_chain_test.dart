import 'package:fileshare/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildAuditLogEntry produces verifiable hash chain entries', () {
    final first = buildAuditLogEntry(
      seq: 1,
      event: 'transfer_started',
      data: <String, dynamic>{'name': 'a.txt', 'bytes': 100},
      prevHash: '',
      timestampUtc: DateTime.utc(2026, 2, 20, 0, 0, 0),
    );
    final second = buildAuditLogEntry(
      seq: 2,
      event: 'transfer_finished',
      data: <String, dynamic>{'name': 'a.txt', 'state': 'completed'},
      prevHash: first['hash'] as String,
      timestampUtc: DateTime.utc(2026, 2, 20, 0, 0, 5),
    );

    final verification = verifyAuditChainEntries([first, second]);
    expect(verification.valid, isTrue);
    expect(verification.validEntries, 2);
    expect(verification.lastHash, second['hash']);
  });

  test('computeAuditEntryHash is stable regardless map key ordering', () {
    final a = <String, dynamic>{
      'seq': 1,
      'ts': '2026-02-20T00:00:00.000Z',
      'event': 'x',
      'data': <String, dynamic>{'b': 2, 'a': 1},
      'prevHash': '',
    };
    final b = <String, dynamic>{
      'prevHash': '',
      'data': <String, dynamic>{'a': 1, 'b': 2},
      'event': 'x',
      'ts': '2026-02-20T00:00:00.000Z',
      'seq': 1,
    };
    expect(computeAuditEntryHash(a), computeAuditEntryHash(b));
  });

  test('verifyAuditChainEntries detects tampering', () {
    final first = buildAuditLogEntry(
      seq: 1,
      event: 'transfer_started',
      data: <String, dynamic>{'name': 'b.txt'},
      prevHash: '',
      timestampUtc: DateTime.utc(2026, 2, 20, 0, 0, 0),
    );
    final second = buildAuditLogEntry(
      seq: 2,
      event: 'transfer_finished',
      data: <String, dynamic>{'name': 'b.txt', 'state': 'completed'},
      prevHash: first['hash'] as String,
      timestampUtc: DateTime.utc(2026, 2, 20, 0, 0, 4),
    );
    final tampered = Map<String, dynamic>.from(second);
    tampered['data'] = <String, dynamic>{'name': 'b.txt', 'state': 'failed'};

    final verification = verifyAuditChainEntries([first, tampered]);
    expect(verification.valid, isFalse);
    expect(verification.firstInvalidIndex, 1);
    expect(verification.validEntries, 1);
  });
}
