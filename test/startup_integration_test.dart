import 'package:fileshare/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildWindowsStartupCommand quotes executable path', () {
    final command = buildWindowsStartupCommand(
      executablePath: r'C:\Program Files\FileShare\fileshare.exe',
      startInTray: false,
    );
    expect(command, r'"C:\Program Files\FileShare\fileshare.exe"');
  });

  test('buildWindowsStartupCommand appends tray arg when requested', () {
    final command = buildWindowsStartupCommand(
      executablePath: r'C:\Apps\fileshare.exe',
      startInTray: true,
    );
    expect(command, r'"C:\Apps\fileshare.exe" --start-in-tray');
  });
}
