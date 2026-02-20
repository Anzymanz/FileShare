import 'package:fileshare/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('updateChannel string conversion roundtrip', () {
    for (final channel in UpdateChannel.values) {
      final encoded = updateChannelToString(channel);
      final decoded = updateChannelFromString(encoded);
      expect(decoded, channel);
    }
  });

  test('updateChannelFromString defaults to stable on unknown input', () {
    expect(updateChannelFromString('unknown'), UpdateChannel.stable);
    expect(updateChannelFromString(null), UpdateChannel.stable);
  });

  test('AppSettings serializes update channel', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      updateChannel: UpdateChannel.beta,
    );

    final json = settings.toJson();
    final restored = AppSettings.fromJson(json);
    expect(restored.updateChannel, UpdateChannel.beta);
  });

  test('duplicate handling mode string conversion roundtrip', () {
    for (final mode in DuplicateHandlingMode.values) {
      final encoded = duplicateHandlingModeToString(mode);
      final decoded = duplicateHandlingModeFromString(encoded);
      expect(decoded, mode);
    }
    expect(
      duplicateHandlingModeFromString('unknown'),
      DuplicateHandlingMode.rename,
    );
    expect(duplicateHandlingModeFromString(null), DuplicateHandlingMode.rename);
  });

  test('AppSettings serializes duplicate handling mode', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      duplicateHandlingMode: DuplicateHandlingMode.skip,
    );

    final json = settings.toJson();
    final restored = AppSettings.fromJson(json);
    expect(restored.duplicateHandlingMode, DuplicateHandlingMode.skip);
  });

  test('AppSettings serializes room channel', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      roomChannel: 'Team Alpha',
    );

    final json = settings.toJson();
    final restored = AppSettings.fromJson(json);
    expect(restored.roomChannel, 'team-alpha');
  });
}
