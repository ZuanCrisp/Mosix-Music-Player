import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/automix_phase_lock.dart';

void main() {
  void samples(AutoMixPhaseLock lock, List<double?> errors) {
    for (var index = 0; index < errors.length; index++) {
      lock.observe(Duration(milliseconds: 300 + index * 200), errors[index]);
    }
  }

  test('stable drift gets a bounded correction then a settling interval', () {
    for (final error in [-0.035, 0.035]) {
      final lock = AutoMixPhaseLock(baseRate: 0.96, period: 0.5);
      samples(lock, [error, error + 0.002, error - 0.002]);
      final rate = lock.rateAt(const Duration(milliseconds: 700));
      expect(rate, closeTo(0.96 * (error < 0 ? 1.02 : 0.98), 0.00001));
      expect(lock.shouldMeasure(const Duration(milliseconds: 1000)), isFalse);
      expect(lock.rateAt(const Duration(milliseconds: 1300)), 0.96);
      expect(lock.shouldMeasure(const Duration(milliseconds: 1400)), isFalse);
      expect(lock.shouldMeasure(const Duration(milliseconds: 1600)), isTrue);
    }
  });

  test(
    'aligned playback and conflicting reports do not cause speed changes',
    () {
      for (final errors in [
        [0.005, -0.005, 0.01],
        [-0.06, 0.06, 0.03],
      ]) {
        final lock = AutoMixPhaseLock(baseRate: 1, period: 0.5);
        samples(lock, errors);
        expect(lock.rateAt(const Duration(milliseconds: 700)), 1);
        expect(lock.trusted, isTrue);
      }
    },
  );

  test(
    'missing positions and large discontinuities invalidate phase tracking',
    () {
      for (final error in [null, double.nan, 0.3]) {
        final lock = AutoMixPhaseLock(baseRate: 1, period: 0.5);
        samples(lock, [error, error, error]);
        expect(lock.trusted, isFalse);
        expect(lock.shouldMeasure(const Duration(seconds: 3)), isFalse);
        expect(lock.rateAt(const Duration(seconds: 3)), 1);
      }
    },
  );

  test('correction never exceeds the total playback speed bounds', () {
    for (final base in [0.905, 1.095]) {
      final lock = AutoMixPhaseLock(baseRate: base, period: 0.5);
      final error = base < 1 ? 0.04 : -0.04;
      samples(lock, [error, error, error]);
      expect(
        lock.rateAt(const Duration(milliseconds: 700)),
        inInclusiveRange(0.90, 1.10),
      );
    }
  });
}
