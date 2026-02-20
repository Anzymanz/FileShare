import 'package:fileshare/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildNetworkDiagnosticsHints includes core firewall guidance', () {
    final hints = buildNetworkDiagnosticsHints(
      connectedPeers: 1,
      localIps: const ['192.168.0.10'],
      diagnostics: const <String, int>{},
      hasIncompatiblePeers: false,
      roomKeyEnabled: false,
    );

    expect(
      hints.any((h) => h.toLowerCase().contains('firewall')),
      isTrue,
    );
  });

  test('buildNetworkDiagnosticsHints flags no-peer and auth mismatch cases', () {
    final hints = buildNetworkDiagnosticsHints(
      connectedPeers: 0,
      localIps: const [],
      diagnostics: const <String, int>{
        'udp_auth_drop': 2,
        'tcp_protocol_mismatch': 1,
      },
      hasIncompatiblePeers: true,
      roomKeyEnabled: true,
    );

    expect(hints.any((h) => h.toLowerCase().contains('no peers connected')), isTrue);
    expect(hints.any((h) => h.toLowerCase().contains('room key')), isTrue);
    expect(hints.any((h) => h.toLowerCase().contains('version mismatch')), isTrue);
    expect(hints.any((h) => h.toLowerCase().contains('protocol mismatch')), isTrue);
  });
}
