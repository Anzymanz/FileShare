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

  test('AppSettings serializes transfer/global rate caps', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      transferRateLimitMBps: 25,
      globalRateLimitMBps: 200,
    );

    final json = settings.toJson();
    final restored = AppSettings.fromJson(json);
    expect(restored.transferRateLimitMBps, 25);
    expect(restored.globalRateLimitMBps, 200);
  });

  test('AppSettings clamps invalid transfer/global rate caps', () {
    final restored = AppSettings.fromJson(<String, dynamic>{
      'darkMode': true,
      'themeIndex': 0,
      'soundOnNudge': false,
      'transferRateLimitMBps': 0,
      'globalRateLimitMBps': 999999,
    });

    expect(restored.transferRateLimitMBps, 1);
    expect(restored.globalRateLimitMBps, 5000);
  });

  test('AppSettings serializes preview panel preference', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      showPreviewPanel: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.showPreviewPanel, isTrue);
  });
}
