import 'package:fileshare/main.dart';
import 'package:flutter/material.dart';
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
}
