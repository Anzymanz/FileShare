import 'package:fileshare/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolveMinimizeAction uses tray hide only when enabled on Windows', () {
    expect(
      resolveMinimizeAction(minimizeToTray: true, isWindows: true),
      MinimizeAction.hideToTray,
    );
    expect(
      resolveMinimizeAction(minimizeToTray: false, isWindows: true),
      MinimizeAction.minimizeWindow,
    );
    expect(
      resolveMinimizeAction(minimizeToTray: true, isWindows: false),
      MinimizeAction.minimizeWindow,
    );
  });
}
