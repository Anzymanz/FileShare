import 'package:fileshare/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings menu opens and triggers network settings callback', (
    WidgetTester tester,
  ) async {
    var showSettingsCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsButton(
            dark: true,
            themeIndex: 0,
            connectedCount: 1,
            minimizeToTray: false,
            onToggleTheme: () {},
            onSelectTheme: (_) {},
            onShowSettings: () => showSettingsCalls++,
            onToggleMinimizeToTray: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Network settings'));
    await tester.pumpAndSettle();

    expect(showSettingsCalls, 1);
  });

  testWidgets('settings menu triggers minimize to tray toggle callback', (
    WidgetTester tester,
  ) async {
    var toggleCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsButton(
            dark: true,
            themeIndex: 0,
            connectedCount: 1,
            minimizeToTray: false,
            onToggleTheme: () {},
            onSelectTheme: (_) {},
            onShowSettings: () {},
            onToggleMinimizeToTray: () => toggleCalls++,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckedPopupMenuItem<int>));
    await tester.pumpAndSettle();

    expect(toggleCalls, 1);
  });

  testWidgets('remote icon tile context menu triggers Download As', (
    WidgetTester tester,
  ) async {
    var downloadCalls = 0;
    final item = ShareItem(
      ownerId: 'peer-a',
      owner: 'Peer A',
      itemId: 'item-1',
      name: 'example.txt',
      rel: 'example.txt',
      size: 123,
      local: false,
      path: null,
      iconBytes: null,
      peerId: 'peer-a',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 180,
              child: IconTile(
                item: item,
                createItem: (_) async => null,
                isFavorite: false,
                onToggleFavorite: () {},
                onRemove: null,
                onDownload: () async => downloadCalls++,
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == 'DraggableWidget',
      ),
      findsOneWidget,
    );

    final center = tester.getCenter(find.byType(IconTile));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.addPointer(location: center);
    await tester.pump();
    await gesture.down(center);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Download As...'), findsOneWidget);
    await tester.tap(find.text('Download As...'));
    await tester.pumpAndSettle();
    expect(downloadCalls, 1);
  });

  testWidgets('local icon tile context menu triggers Remove', (
    WidgetTester tester,
  ) async {
    var removeCalls = 0;
    final item = ShareItem(
      ownerId: 'local',
      owner: 'This PC',
      itemId: 'item-2',
      name: 'local.txt',
      rel: 'local.txt',
      size: 64,
      local: true,
      path: r'C:\tmp\local.txt',
      iconBytes: null,
      peerId: null,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 180,
              child: IconTile(
                item: item,
                createItem: (_) async => null,
                isFavorite: false,
                onToggleFavorite: () {},
                onRemove: () => removeCalls++,
                onDownload: null,
              ),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(IconTile));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.addPointer(location: center);
    await tester.pump();
    await gesture.down(center);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Remove'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(removeCalls, 1);
  });

  testWidgets('icon tile context menu toggles Pin action', (
    WidgetTester tester,
  ) async {
    var pinCalls = 0;
    final item = ShareItem(
      ownerId: 'peer-a',
      owner: 'Peer A',
      itemId: 'item-3',
      name: 'pin-me.txt',
      rel: 'pin-me.txt',
      size: 32,
      local: false,
      path: null,
      iconBytes: null,
      peerId: 'peer-a',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 180,
              child: IconTile(
                item: item,
                createItem: (_) async => null,
                isFavorite: false,
                onToggleFavorite: () => pinCalls++,
                onRemove: null,
                onDownload: null,
              ),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(IconTile));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.addPointer(location: center);
    await tester.pump();
    await gesture.down(center);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Pin'), findsOneWidget);
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();
    expect(pinCalls, 1);
  });

  testWidgets('icon tile context menu triggers Edit Note action', (
    WidgetTester tester,
  ) async {
    var noteCalls = 0;
    final item = ShareItem(
      ownerId: 'peer-a',
      owner: 'Peer A',
      itemId: 'item-4',
      name: 'note-me.txt',
      rel: 'note-me.txt',
      size: 44,
      local: false,
      path: null,
      iconBytes: null,
      peerId: 'peer-a',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 180,
              child: IconTile(
                item: item,
                createItem: (_) async => null,
                isFavorite: false,
                onToggleFavorite: () {},
                onEditNote: () async => noteCalls++,
                onRemove: null,
                onDownload: null,
              ),
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(IconTile));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.addPointer(location: center);
    await tester.pump();
    await gesture.down(center);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Edit Note...'), findsOneWidget);
    await tester.tap(find.text('Edit Note...'));
    await tester.pumpAndSettle();
    expect(noteCalls, 1);
  });
}
