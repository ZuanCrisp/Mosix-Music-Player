import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// Readback uses 8-bit sRGB. Cache each channel's exact Flutter luminance
// contribution (6 KiB total), avoiding three powers and a Color per pixel.
final _redLuminance = Float64List.fromList(
  List.generate(
    256,
    (value) => Color.fromARGB(255, value, 0, 0).computeLuminance(),
  ),
);
final _greenLuminance = Float64List.fromList(
  List.generate(
    256,
    (value) => Color.fromARGB(255, 0, value, 0).computeLuminance(),
  ),
);
final _blueLuminance = Float64List.fromList(
  List.generate(
    256,
    (value) => Color.fromARGB(255, 0, 0, value).computeLuminance(),
  ),
);

/// Matches [Color.computeLuminance] for an RGB pixel from an 8-bit readback.
double artworkPixelLuminance(int red, int green, int blue) =>
    _redLuminance[red] + _greenLuminance[green] + _blueLuminance[blue];

/// Samples rendered video and its fade, rather than a static album palette.
/// Read back only 48 pixels across, at most three times a second when visible.
class MornyeArtworkContrast extends StatefulWidget {
  const MornyeArtworkContrast({
    super.key,
    required this.enabled,
    required this.targets,
    required this.onChanged,
    required this.child,
  });

  final bool enabled;
  final Map<String, GlobalKey> targets;
  final ValueChanged<Map<String, Color>> onChanged;
  final Widget child;

  @override
  State<MornyeArtworkContrast> createState() => _MornyeArtworkContrastState();
}

class _MornyeArtworkContrastState extends State<MornyeArtworkContrast>
    with WidgetsBindingObserver {
  final _background = GlobalKey();
  Timer? _timer;
  bool _sampling = false;
  Map<String, Color> _colors = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _schedule();

  @override
  void didUpdateWidget(MornyeArtworkContrast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!widget.enabled) {
      _colors = {};
      return;
    }
    // Playback can keep the Dart isolate alive after the UI is backgrounded.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _sample());
    _timer = Timer.periodic(
      const Duration(milliseconds: 333),
      (_) => _sample(),
    );
  }

  Future<void> _sample() async {
    if (!mounted || !widget.enabled || _sampling) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final route = ModalRoute.of(context);
    if (route != null &&
        (!route.isCurrent || route.animation?.isAnimating == true)) {
      return;
    }
    final boundary = _background.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary ||
        !boundary.hasSize ||
        boundary.debugNeedsPaint ||
        boundary.size.isEmpty) {
      return;
    }
    _sampling = true;
    ui.Image? image;
    try {
      final scale = (48 / boundary.size.width).clamp(0.01, 1.0);
      image = await boundary.toImage(pixelRatio: scale);
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (!mounted || !widget.enabled || pixels == null) return;
      final origin = boundary.localToGlobal(Offset.zero);
      final next = <String, Color>{};
      for (final entry in widget.targets.entries) {
        final target = entry.value.currentContext?.findRenderObject();
        if (target is! RenderBox || !target.hasSize || !target.attached) {
          continue;
        }
        final rect = target.localToGlobal(Offset.zero) - origin & target.size;
        final left = (rect.left * scale).floor().clamp(0, image.width);
        final right = (rect.right * scale).ceil().clamp(0, image.width);
        final top = (rect.top * scale).floor().clamp(0, image.height);
        final bottom = (rect.bottom * scale).ceil().clamp(0, image.height);
        var luminance = 0.0;
        var count = 0;
        for (var y = top; y < bottom; y++) {
          for (var x = left; x < right; x++) {
            final index = (y * image.width + x) * 4;
            luminance += artworkPixelLuminance(
              pixels.getUint8(index),
              pixels.getUint8(index + 1),
              pixels.getUint8(index + 2),
            );
            count++;
          }
        }
        if (count == 0) continue;
        // Prefer the player's white labels/icons while they retain 3:1
        // contrast. Pastel frames need not switch to black merely because
        // black has a higher contrast ratio. Hysteresis prevents flicker.
        final threshold = _colors[entry.key] == Colors.black ? 0.28 : 0.30;
        next[entry.key] = luminance / count > threshold
            ? Colors.black
            : Colors.white;
      }
      if (next.entries.any((entry) => _colors[entry.key] != entry.value)) {
        _colors = next;
        widget.onChanged(next);
      }
    } catch (_) {
      // Unreadable surfaces keep the light controls over the dark fade.
    } finally {
      image?.dispose();
      _sampling = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _background, child: widget.child);
}
