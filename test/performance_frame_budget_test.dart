import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/performance_probe.dart';

FrameTiming _frame(int buildUs, int rasterUs) => FrameTiming(
  vsyncStart: 0,
  buildStart: 0,
  buildFinish: buildUs,
  rasterStart: buildUs,
  rasterFinish: buildUs + rasterUs,
  rasterFinishWallTime: buildUs + rasterUs,
);

void main() {
  test('90 and 120 Hz expose frames that fit the 60 Hz reference', () {
    final frames = [
      _frame(7000, 7000),
      _frame(10000, 10000),
      _frame(15000, 4000),
    ];
    final at60 = summarizeFrameBudget(frames, refreshHz: 60);
    final at90 = summarizeFrameBudget(frames, refreshHz: 90);
    final at120 = summarizeFrameBudget(frames, refreshHz: 120);
    expect(at60['over_budget_frames'], 0);
    expect(at90['over_budget_frames'], 1);
    expect(at120['over_budget_frames'], 2);
    expect(at120['build_over_budget_frames'], 2);
    expect(at120['raster_over_budget_frames'], 1);
    expect(at120['over_budget_percent'], closeTo(200 / 3, 0.001));
    expect(at60['total_over_budget_frames'], 2);
  });

  test('idle reports and invalid refresh rates stay finite', () {
    for (final hz in [0.0, -1.0, double.nan, double.infinity]) {
      final summary = summarizeFrameBudget([], refreshHz: hz);
      expect(summary['refresh_hz'], 60);
      expect(summary['over_budget_frames'], 0);
      expect(summary['over_budget_percent'], 0);
      expect(summary['budget_ms'], closeTo(1000 / 60, 0.001));
    }
  });
}
