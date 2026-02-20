import 'package:fileshare/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selectDiscoveryProfile prefers high reliability with no peers', () {
    final profile = selectDiscoveryProfile(
      connectedPeers: 0,
      repeatedFetchFailures: 0,
      rateLimitEvents: 0,
    );
    expect(profile, DiscoveryProfile.highReliability);
  });

  test('selectDiscoveryProfile prefers low traffic for large peer sets', () {
    final profile = selectDiscoveryProfile(
      connectedPeers: 5,
      repeatedFetchFailures: 0,
      rateLimitEvents: 0,
    );
    expect(profile, DiscoveryProfile.lowTraffic);
  });

  test('selectDiscoveryProfile uses balanced in normal conditions', () {
    final profile = selectDiscoveryProfile(
      connectedPeers: 2,
      repeatedFetchFailures: 0,
      rateLimitEvents: 4,
    );
    expect(profile, DiscoveryProfile.balanced);
  });
}
