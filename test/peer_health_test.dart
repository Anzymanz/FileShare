import 'package:fileshare/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('evaluatePeerHealth gives high score for healthy peer', () {
    final result = evaluatePeerHealth(
      contactAge: const Duration(seconds: 1),
      hasManifest: true,
      fetchFailureStreak: 0,
      state: PeerState.reachable,
    );

    expect(result.score, greaterThanOrEqualTo(85));
    expect(result.tier, anyOf('Excellent', 'Good'));
    expect(result.hint, isNotEmpty);
  });

  test('evaluatePeerHealth degrades for stale peers with actionable hint', () {
    final result = evaluatePeerHealth(
      contactAge: const Duration(seconds: 40),
      hasManifest: false,
      fetchFailureStreak: 4,
      state: PeerState.stale,
    );

    expect(result.score, lessThan(40));
    expect(result.tier, 'Poor');
    final hint = result.hint.toLowerCase();
    expect(
      hint.contains('firewall') || hint.contains('connect tcp'),
      isTrue,
    );
  });

  test('evaluatePeerHealth flags repeated fetch failures', () {
    final result = evaluatePeerHealth(
      contactAge: const Duration(seconds: 3),
      hasManifest: true,
      fetchFailureStreak: 3,
      state: PeerState.reachable,
    );

    expect(result.score, lessThan(80));
    expect(result.hint.toLowerCase(), contains('connect tcp'));
  });
}
