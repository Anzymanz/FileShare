import 'package:fileshare/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildSubnetSweepTargets excludes local host and stays in /24', () {
    final targets = buildSubnetSweepTargets(const ['192.168.0.69']);
    expect(targets.length, 253);
    expect(targets.contains('192.168.0.69'), isFalse);
    expect(targets.first, '192.168.0.1');
    expect(targets.last, '192.168.0.254');
  });

  test('buildSubnetSweepTargets supports multiple subnets and ignores invalid IPs', () {
    final targets = buildSubnetSweepTargets(const [
      '192.168.0.10',
      '192.168.0.20',
      '10.0.1.5',
      'not-an-ip',
    ]);
    expect(targets.contains('192.168.0.10'), isFalse);
    expect(targets.contains('10.0.1.5'), isFalse);
    expect(targets.contains('192.168.0.11'), isTrue);
    expect(targets.contains('10.0.1.6'), isTrue);
  });

  test('buildSubnetSweepTargets respects custom host range', () {
    final targets = buildSubnetSweepTargets(
      const ['192.168.1.2'],
      hostStart: 2,
      hostEnd: 4,
    );
    expect(targets, ['192.168.1.3', '192.168.1.4']);
  });
}
