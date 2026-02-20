import 'package:fileshare/main.dart';
import 'package:flutter_test/flutter_test.dart';

ShareItem _item({
  required String ownerId,
  required String owner,
  required String id,
  required String name,
  required int size,
  required bool local,
}) {
  return ShareItem(
    ownerId: ownerId,
    owner: owner,
    itemId: id,
    name: name,
    rel: name,
    size: size,
    local: local,
    path: local ? r'C:\tmp\placeholder' : null,
    iconBytes: null,
    peerId: local ? null : ownerId,
  );
}

void main() {
  test('computeVisibleItems filters by source and search text', () {
    final items = [
      _item(
        ownerId: 'local',
        owner: 'This PC',
        id: '1',
        name: 'photo.jpg',
        size: 1200,
        local: true,
      ),
      _item(
        ownerId: 'peer-a',
        owner: 'Office-PC',
        id: '2',
        name: 'report.pdf',
        size: 1800,
        local: false,
      ),
    ];

    final result = computeVisibleItems(
      items: items,
      query: 'office',
      sourceFilter: ItemSourceFilter.remote,
      typeFilter: ItemTypeFilter.all,
      sortMode: ItemSortMode.nameAsc,
      firstSeenByKey: const <String, DateTime>{},
    );

    expect(result.length, 1);
    expect(result.first.name, 'report.pdf');
  });

  test('computeVisibleItems filters by item type', () {
    final items = [
      _item(
        ownerId: 'peer-a',
        owner: 'Office-PC',
        id: '1',
        name: 'image.png',
        size: 100,
        local: false,
      ),
      _item(
        ownerId: 'peer-a',
        owner: 'Office-PC',
        id: '2',
        name: 'archive.zip',
        size: 100,
        local: false,
      ),
    ];

    final images = computeVisibleItems(
      items: items,
      query: '',
      sourceFilter: ItemSourceFilter.all,
      typeFilter: ItemTypeFilter.image,
      sortMode: ItemSortMode.nameAsc,
      firstSeenByKey: const <String, DateTime>{},
    );
    final archives = computeVisibleItems(
      items: items,
      query: '',
      sourceFilter: ItemSourceFilter.all,
      typeFilter: ItemTypeFilter.archive,
      sortMode: ItemSortMode.nameAsc,
      firstSeenByKey: const <String, DateTime>{},
    );

    expect(images.map((e) => e.name).toList(), ['image.png']);
    expect(archives.map((e) => e.name).toList(), ['archive.zip']);
  });

  test('computeVisibleItems sorts by size and added timestamp', () {
    final a = _item(
      ownerId: 'peer-a',
      owner: 'Peer-A',
      id: '1',
      name: 'a.txt',
      size: 10,
      local: false,
    );
    final b = _item(
      ownerId: 'peer-a',
      owner: 'Peer-A',
      id: '2',
      name: 'b.txt',
      size: 100,
      local: false,
    );
    final items = [a, b];
    final firstSeen = <String, DateTime>{
      a.key: DateTime.parse('2026-02-20T00:00:01Z'),
      b.key: DateTime.parse('2026-02-20T00:00:02Z'),
    };

    final bySize = computeVisibleItems(
      items: items,
      query: '',
      sourceFilter: ItemSourceFilter.all,
      typeFilter: ItemTypeFilter.all,
      sortMode: ItemSortMode.sizeDesc,
      firstSeenByKey: firstSeen,
    );
    final byDate = computeVisibleItems(
      items: items,
      query: '',
      sourceFilter: ItemSourceFilter.all,
      typeFilter: ItemTypeFilter.all,
      sortMode: ItemSortMode.dateAddedDesc,
      firstSeenByKey: firstSeen,
    );

    expect(bySize.first.name, 'b.txt');
    expect(byDate.first.name, 'b.txt');
  });

  test(
    'partitionPinnedItems splits pinned and non-pinned while preserving order',
    () {
      final a = _item(
        ownerId: 'local',
        owner: 'This PC',
        id: '1',
        name: 'a.txt',
        size: 1,
        local: true,
      );
      final b = _item(
        ownerId: 'peer',
        owner: 'Peer',
        id: '2',
        name: 'b.txt',
        size: 2,
        local: false,
      );
      final c = _item(
        ownerId: 'peer',
        owner: 'Peer',
        id: '3',
        name: 'c.txt',
        size: 3,
        local: false,
      );
      final split = partitionPinnedItems(
        items: [a, b, c],
        favoriteKeys: {b.key},
      );
      expect(split.pinned.map((e) => e.name).toList(), ['b.txt']);
      expect(split.others.map((e) => e.name).toList(), ['a.txt', 'c.txt']);
    },
  );

  test('buildClipboardShareName returns stable timestamped txt filename', () {
    final name = buildClipboardShareName(DateTime(2026, 2, 20, 15, 4, 9));
    expect(name, 'Clipboard_20260220_150409.txt');
  });

  test('parseTrustListInput normalizes and de-duplicates entries', () {
    final parsed = parseTrustListInput(
      ' 192.168.0.10 ; PEER-ABC \n192.168.0.10,peer-abc  ',
    );
    expect(parsed, {'192.168.0.10', 'peer-abc'});
    expect(trustListToText(parsed), '192.168.0.10\npeer-abc');
  });

  test('buildTrustCandidateKeys emits id/ip/ip:port variants', () {
    final keys = buildTrustCandidateKeys(
      peerId: 'PEER-XYZ',
      address: '192.168.0.20',
      port: 40406,
    );
    expect(keys, {'peer-xyz', '192.168.0.20', '192.168.0.20:40406'});
  });

  test('buildPeerFingerprint is deterministic and normalized', () {
    final a = buildPeerFingerprint('PEER-XYZ');
    final b = buildPeerFingerprint('peer-xyz');
    final c = buildPeerFingerprint('other-peer');
    expect(a, b);
    expect(c, isNot(a));
    expect(a, matches(RegExp(r'^[A-F0-9]{4}(-[A-F0-9]{4}){3}$')));
  });

  test('summarizeSelectedItems splits local/remote and owner targets', () {
    final local = _item(
      ownerId: 'local',
      owner: 'This PC',
      id: '1',
      name: 'a.txt',
      size: 1,
      local: true,
    );
    final remoteA = _item(
      ownerId: 'peer-a',
      owner: 'Peer A',
      id: '2',
      name: 'b.txt',
      size: 2,
      local: false,
    );
    final remoteB = _item(
      ownerId: 'peer-b',
      owner: 'Peer B',
      id: '3',
      name: 'c.txt',
      size: 3,
      local: false,
    );
    final summary = summarizeSelectedItems(
      allItems: [local, remoteA, remoteB],
      selectedKeys: {local.key, remoteB.key},
    );
    expect(summary.all.map((e) => e.key).toSet(), {local.key, remoteB.key});
    expect(summary.local.map((e) => e.key).toSet(), {local.key});
    expect(summary.remote.map((e) => e.key).toSet(), {remoteB.key});
    expect(summary.remoteOwnerIds, {'peer-b'});
  });

  test('normalizeItemNote trims and caps note length', () {
    expect(normalizeItemNote('   hello note   '), 'hello note');
    expect(normalizeItemNote('   '), '');
    final long = 'x' * 500;
    expect(normalizeItemNote(long).length, lessThanOrEqualTo(300));
  });

  test('normalizeSha256Hex validates and normalizes checksum values', () {
    expect(normalizeSha256Hex(null), isNull);
    expect(normalizeSha256Hex('abc'), isNull);
    expect(
      normalizeSha256Hex('A' * 64),
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(
      normalizeSha256Hex(
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcg',
      ),
      isNull,
    );
  });

  test('normalizeRoomChannel sanitizes room names', () {
    expect(normalizeRoomChannel(' Team Alpha '), 'team-alpha');
    expect(normalizeRoomChannel(''), '');
    expect(normalizeRoomChannel('___ROOM___'), '___room___');
    expect(normalizeRoomChannel('x' * 100).length, lessThanOrEqualTo(64));
  });

  test('previewKindForName detects image/text/pdf and unsupported types', () {
    expect(previewKindForName('photo.png'), ItemPreviewKind.image);
    expect(previewKindForName('notes.md'), ItemPreviewKind.text);
    expect(previewKindForName('manual.pdf'), ItemPreviewKind.pdf);
    expect(previewKindForName('archive.zip'), ItemPreviewKind.unsupported);
  });

  test('supportsInlinePreviewForName returns expected capability', () {
    expect(supportsInlinePreviewForName('README.txt'), isTrue);
    expect(supportsInlinePreviewForName('diagram.jpg'), isTrue);
    expect(supportsInlinePreviewForName('doc.pdf'), isTrue);
    expect(supportsInlinePreviewForName('video.mp4'), isFalse);
  });

  test('window layout preset helpers upsert/remove/lookup by slot', () {
    final a = WindowLayoutPreset(
      slot: 1,
      left: 0,
      top: 0,
      width: 800,
      height: 500,
      maximized: false,
    );
    final b = WindowLayoutPreset(
      slot: 2,
      left: 100,
      top: 50,
      width: 1000,
      height: 700,
      maximized: true,
    );
    final merged = upsertWindowLayoutPreset([a], b);
    expect(merged.length, 2);
    expect(windowLayoutPresetForSlot(merged, 2)?.maximized, isTrue);

    final replaced = upsertWindowLayoutPreset(
      merged,
      const WindowLayoutPreset(
        slot: 2,
        left: 200,
        top: 120,
        width: 1200,
        height: 800,
        maximized: false,
      ),
    );
    expect(windowLayoutPresetForSlot(replaced, 2)?.left, 200);
    expect(windowLayoutPresetForSlot(replaced, 2)?.maximized, isFalse);

    final removed = removeWindowLayoutPreset(replaced, 1);
    expect(windowLayoutPresetForSlot(removed, 1), isNull);
    expect(windowLayoutPresetForSlot(removed, 2), isNotNull);
  });

  test(
    'computeTaskbarTransferProgress returns -1 when no running transfers',
    () {
      final done = TransferEntry(
        id: 't1',
        name: 'done.bin',
        peerName: 'Peer',
        direction: TransferDirection.download,
        totalBytes: 100,
        startedAt: DateTime.now(),
      )..complete(state: TransferState.completed);
      expect(computeTaskbarTransferProgress([done]), -1);
    },
  );

  test(
    'computeTaskbarTransferProgress aggregates running transfer progress',
    () {
      final a = TransferEntry(
        id: 't1',
        name: 'a.bin',
        peerName: 'Peer',
        direction: TransferDirection.download,
        totalBytes: 100,
        startedAt: DateTime.now(),
      )..transferredBytes = 25;
      final b = TransferEntry(
        id: 't2',
        name: 'b.bin',
        peerName: 'Peer',
        direction: TransferDirection.download,
        totalBytes: 300,
        startedAt: DateTime.now(),
      )..transferredBytes = 150;
      final progress = computeTaskbarTransferProgress([a, b]);
      expect(progress, closeTo(0.4375, 0.0001));
    },
  );

  test(
    'computeTaskbarTransferProgress treats zero-byte running transfer as complete',
    () {
      final empty = TransferEntry(
        id: 't1',
        name: 'empty.txt',
        peerName: 'Peer',
        direction: TransferDirection.download,
        totalBytes: 0,
        startedAt: DateTime.now(),
      );
      expect(computeTaskbarTransferProgress([empty]), 1);
    },
  );

  test(
    'TransferEntry clamps initial transferred bytes for resume progress',
    () {
      final resumed = TransferEntry(
        id: 't-resume',
        name: 'resume.bin',
        peerName: 'Peer',
        direction: TransferDirection.download,
        totalBytes: 100,
        startedAt: DateTime.now(),
        initialTransferredBytes: 45,
      );
      expect(resumed.transferredBytes, 45);

      final oversized = TransferEntry(
        id: 't-oversized',
        name: 'oversized.bin',
        peerName: 'Peer',
        direction: TransferDirection.download,
        totalBytes: 100,
        startedAt: DateTime.now(),
        initialTransferredBytes: 999,
      );
      expect(oversized.transferredBytes, 100);
    },
  );

  test('parseLaunchSharePaths filters flags and de-duplicates paths', () {
    final parsed = parseLaunchSharePaths([
      '--start-in-tray',
      r'C:\Temp\a.txt',
      r'"C:\Temp\a.txt"',
      r'C:\Temp\b.txt',
      '--verbose',
      '',
    ]);
    expect(parsed, [r'C:\Temp\a.txt', r'C:\Temp\b.txt']);
  });

  test('room key expiry labels and status text are stable', () {
    expect(roomKeyExpiryOptionLabel(0), 'Off');
    expect(roomKeyExpiryOptionLabel(15), '15 min');
    expect(roomKeyExpiryOptionLabel(120), '2 h');

    expect(
      describeRoomKeyExpiryStatus(
        sharedRoomKey: '',
        expiryMinutes: 15,
        expiresAt: DateTime.parse('2026-02-20T10:15:00Z'),
        now: DateTime.parse('2026-02-20T10:00:00Z'),
      ),
      'No room key set.',
    );
    expect(
      describeRoomKeyExpiryStatus(
        sharedRoomKey: 'abc',
        expiryMinutes: 0,
        expiresAt: null,
        now: DateTime.parse('2026-02-20T10:00:00Z'),
      ),
      'Room key does not expire in this session.',
    );
    expect(
      describeRoomKeyExpiryStatus(
        sharedRoomKey: 'abc',
        expiryMinutes: 15,
        expiresAt: DateTime.parse('2026-02-20T10:16:00Z'),
        now: DateTime.parse('2026-02-20T10:00:01Z'),
      ),
      'Room key expires in about 16 min.',
    );
  });
}
