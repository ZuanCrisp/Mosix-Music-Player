import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Live test bindings otherwise request another engine frame after every draw,
/// even when the app is idle. Service only frames requested by the framework.
class PerformanceTestBinding extends IntegrationTestWidgetsFlutterBinding {
  static PerformanceTestBinding? _benchmarkInstance;

  static PerformanceTestBinding ensureInitialized() =>
      _benchmarkInstance ??= PerformanceTestBinding();

  bool _requestedFrame = false;

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    _requestedFrame = hasScheduledFrame || rawTimeStamp == null;
    if (_requestedFrame) super.handleBeginFrame(rawTimeStamp);
  }

  @override
  void handleDrawFrame() {
    if (_requestedFrame) super.handleDrawFrame();
    _requestedFrame = false;
  }
}

/// Device-only measurements: the engine drives frames, never a pumped clock.
class PerformanceProbe {
  PerformanceProbe(this.binding, this.tester, {required this.suite}) {
    final previousPolicy = binding.framePolicy;
    binding.framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
    addTearDown(() => binding.framePolicy = previousPolicy);
  }

  final IntegrationTestWidgetsFlutterBinding binding;
  final WidgetTester tester;
  final String suite;
  final List<Map<String, Object?>> _scenarios = [];
  static const _budgetUs = 1000000 / 60;

  /// Also safe outside [measure]: integration bindings use real timers.
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);

  Future<void> scroll(
    ScrollController controller, {
    required double distance,
    Duration duration = const Duration(milliseconds: 900),
  }) async {
    final position = controller.position;
    await controller.animateTo(
      (position.pixels + distance).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
      duration: duration,
      curve: Curves.linear,
    );
    await wait(const Duration(milliseconds: 150));
  }

  Future<void> measure(
    String name,
    Future<void> Function() action, {
    Future<void> Function()? warmup,
    int repetitions = 3,
    bool allowIdle = false,
  }) async {
    assert(repetitions > 0);
    final runs = <Map<String, Object?>>[];
    final allFrames = <ui.FrameTiming>[];
    await tester.runAsync(() async {
      await (warmup ?? action)();
      await wait(const Duration(milliseconds: 300));
      for (var repetition = 0; repetition < repetitions; repetition++) {
        final frames = <ui.FrameTiming>[];
        void collect(List<ui.FrameTiming> batch) => frames.addAll(batch);
        binding.addTimingsCallback(collect);
        final startUs = binding.currentSystemFrameTimeStamp.inMicroseconds;
        final rssBefore = ProcessInfo.currentRss;
        final elapsed = Stopwatch()..start();
        late int endUs;
        late int rssAfter;
        try {
          await action();
          elapsed.stop();
          endUs = binding.currentSystemFrameTimeStamp.inMicroseconds;
          rssAfter = ProcessInfo.currentRss;
          // Engine timing callbacks can arrive in batches once per second.
          // Exclude the drain's frames using the recorded vsync boundaries.
          await wait(const Duration(milliseconds: 1100));
        } finally {
          binding.removeTimingsCallback(collect);
        }
        frames.removeWhere((frame) {
          final vsync = frame.timestampInMicroseconds(ui.FramePhase.vsyncStart);
          return vsync <= startUs || vsync > endUs;
        });
        if (!allowIdle && frames.isEmpty) {
          fail('$name produced no real engine FrameTiming samples');
        }
        allFrames.addAll(frames);
        runs.add({
          'repetition': repetition + 1,
          'elapsed_ms': elapsed.elapsedMicroseconds / 1000,
          'rss_before_bytes': rssBefore,
          'rss_after_bytes': rssAfter,
          'rss_delta_bytes': rssAfter - rssBefore,
          ..._summarize(frames),
          'samples_us': [
            for (final frame in frames)
              [
                frame.buildDuration.inMicroseconds,
                frame.rasterDuration.inMicroseconds,
                frame.totalSpan.inMicroseconds,
              ],
          ],
        });
      }
    });
    expect(tester.takeException(), isNull, reason: name);
    expect(runs, hasLength(repetitions), reason: name);
    final scenario = <String, Object?>{
      'name': name,
      'runs': runs,
      'summary': _summarize(allFrames),
    };
    _scenarios.add(scenario);
    debugPrint(
      'PERFORMANCE_SCENARIO: ${jsonEncode({'name': name, ..._summarize(allFrames), 'rss_delta_bytes': runs.map((run) => run['rss_delta_bytes']).toList()})}',
    );
  }

  Map<String, Object?> _summarize(List<ui.FrameTiming> frames) {
    final build = frames.map((frame) => frame.buildDuration.inMicroseconds);
    final raster = frames.map((frame) => frame.rasterDuration.inMicroseconds);
    final total = frames.map((frame) => frame.totalSpan.inMicroseconds);
    final missed = frames
        .where(
          (frame) =>
              math.max(
                frame.buildDuration.inMicroseconds,
                frame.rasterDuration.inMicroseconds,
              ) >
              _budgetUs,
        )
        .length;
    return {
      'frames': frames.length,
      'build_ms': _percentiles(build),
      'raster_ms': _percentiles(raster),
      'total_span_ms': _percentiles(total),
      'over_16_67ms_frames': missed,
      'over_16_67ms_percent': frames.isEmpty ? 0 : missed * 100 / frames.length,
      'build_over_16_67ms_frames': build
          .where((time) => time > _budgetUs)
          .length,
      'raster_over_16_67ms_frames': raster
          .where((time) => time > _budgetUs)
          .length,
      'total_over_16_67ms_frames': total
          .where((time) => time > _budgetUs)
          .length,
    };
  }

  Map<String, double?> _percentiles(Iterable<int> values) {
    final sorted = values.toList()..sort();
    double? at(double fraction) => sorted.isEmpty
        ? null
        : sorted[math.max(0, (sorted.length * fraction).ceil() - 1)] / 1000;
    return {
      'p50': at(0.50),
      'p90': at(0.90),
      'p95': at(0.95),
      'p99': at(0.99),
      'max': at(1),
    };
  }

  Future<File> finish({Map<String, Object?> metadata = const {}}) async {
    final report = <String, Object?>{
      'suite': suite,
      'utc': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
      'mode': kProfileMode
          ? 'profile'
          : kDebugMode
          ? 'debug'
          : 'release',
      'frame_policy': binding.framePolicy.name,
      'framework_requested_frames_only': binding is PerformanceTestBinding,
      'budget_hz': 60,
      'budget_ms': _budgetUs / 1000,
      'budget_basis': 'fixed 60 Hz reference, independent of display refresh',
      'over_budget_definition':
          'max(buildDuration, rasterDuration) > fixed budget',
      'timing_scope': 'engine FrameTiming phases, not displayed FPS',
      'sample_columns': ['build', 'raster', 'total_span'],
      'refresh_hz': tester.view.display.refreshRate,
      'physical_width': tester.view.physicalSize.width,
      'physical_height': tester.view.physicalSize.height,
      'device_pixel_ratio': tester.view.devicePixelRatio,
      'shader_filters_supported': ui.ImageFilter.isShaderFilterSupported,
      'image_cache_bytes': PaintingBinding.instance.imageCache.currentSizeBytes,
      'rss_bytes': ProcessInfo.currentRss,
      'max_rss_bytes': ProcessInfo.maxRss,
      ...metadata,
      'scenarios': _scenarios,
    };
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$suite-performance.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    binding.reportData ??= <String, dynamic>{};
    binding.reportData![suite] = report;
    binding.reportData!['${suite}_report_path'] = file.path;
    debugPrint('PERFORMANCE_REPORT: ${file.path}');
    return file;
  }
}
