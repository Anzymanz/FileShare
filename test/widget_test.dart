import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fileshare/main.dart';

void main() {
  testWidgets('renders minimalist shell', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MyApp(
        initialSettings: AppSettings(
          darkMode: true,
          themeIndex: 0,
          soundOnNudge: false,
        ),
      ),
    );

    expect(find.byType(PopupMenuButton<int>), findsOneWidget);
  });
}
