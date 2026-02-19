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

  test('shouldHideToTrayOnMinimize respects quitting state', () {
    expect(
      shouldHideToTrayOnMinimize(
        minimizeToTray: true,
        isWindows: true,
        isQuitting: false,
      ),
      isTrue,
    );
    expect(
      shouldHideToTrayOnMinimize(
        minimizeToTray: true,
        isWindows: true,
        isQuitting: true,
      ),
      isFalse,
    );
    expect(
      shouldHideToTrayOnMinimize(
        minimizeToTray: true,
        isWindows: false,
        isQuitting: false,
      ),
      isFalse,
    );
  });
}
