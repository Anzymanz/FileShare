import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fileshare/main.dart';

void main() {
  testWidgets('renders minimalist shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Drop files or folders here'), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });
}
