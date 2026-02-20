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

  test('AppSettings serializes room key expiry minutes', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      roomKeyExpiryMinutes: 30,
    );

    final json = settings.toJson();
    final restored = AppSettings.fromJson(json);
    expect(restored.roomKeyExpiryMinutes, 30);
  });

  test('AppSettings clamps invalid room key expiry minutes', () {
    final low = AppSettings.fromJson(<String, dynamic>{
      'darkMode': true,
      'themeIndex': 0,
      'soundOnNudge': false,
      'roomKeyExpiryMinutes': -3,
    });
    expect(low.roomKeyExpiryMinutes, 0);

    final high = AppSettings.fromJson(<String, dynamic>{
      'darkMode': true,
      'themeIndex': 0,
      'soundOnNudge': false,
      'roomKeyExpiryMinutes': 999999,
    });
    expect(high.roomKeyExpiryMinutes, 24 * 60);
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

  test('AppSettings serializes window layout presets', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      windowLayoutPresets: <WindowLayoutPreset>[
        WindowLayoutPreset(
          slot: 1,
          left: 10,
          top: 20,
          width: 900,
          height: 600,
          maximized: false,
          savedAtEpochMs: 123,
          displayHint: 'Center 450,320',
        ),
      ],
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.windowLayoutPresets.length, 1);
    final preset = restored.windowLayoutPresets.first;
    expect(preset.slot, 1);
    expect(preset.width, 900);
    expect(preset.height, 600);
    expect(preset.displayHint, 'Center 450,320');
  });

  test('AppSettings serializes Send To integration preference', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      sendToIntegrationEnabled: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.sendToIntegrationEnabled, isTrue);
  });

  test('AppSettings serializes drag-out compatibility preference', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      dragOutCompatibilityMode: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.dragOutCompatibilityMode, isTrue);
  });

  test('AppSettings serializes handoff mode preference', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      handoffModeEnabled: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.handoffModeEnabled, isTrue);
  });

  test('AppSettings serializes pairing required preference', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      pairingRequired: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.pairingRequired, isTrue);
  });

  test('AppSettings serializes relay mode settings', () {
    const settings = AppSettings(
      darkMode: true,
      themeIndex: 0,
      soundOnNudge: false,
      relayModeEnabled: true,
      relayEndpoints: '192.168.0.10:40406\n192.168.0.11:5000',
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.relayModeEnabled, isTrue);
    expect(restored.relayEndpoints, '192.168.0.10:40406\n192.168.0.11:5000');
  });
}
