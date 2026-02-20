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

  test('partitionPinnedItems splits pinned and non-pinned while preserving order', () {
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
  });
}
