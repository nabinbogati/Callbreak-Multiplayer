import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/design/motion.dart';
import 'package:callbreak/state/app_settings.dart';

/// Every host — the Go server, the LAN host and the solo table — leaves a
/// finished trick on the felt for 1100 ms before clearing it. The throw,
/// gather and sweep must all be over by then, at every animation speed, or
/// the cards vanish mid-flight.
void main() {
  const hostLingerMs = 1100;

  test('the trick sequence fits the host linger at every speed', () {
    for (final speed in AnimationSpeed.values) {
      final scale = Motion.trickScale(speed.durationScale);
      expect(
        Motion.trickAnimationMs * scale,
        lessThan(hostLingerMs),
        reason: '${speed.name} must finish before the trick is cleared',
      );
    }
  });

  test('the cap only ever shortens the trick sequence', () {
    for (final speed in AnimationSpeed.values) {
      expect(Motion.trickScale(speed.durationScale), lessThanOrEqualTo(speed.durationScale));
    }
    expect(Motion.trickScale(1.0), 1.0, reason: 'normal speed is untouched');
  });
}
