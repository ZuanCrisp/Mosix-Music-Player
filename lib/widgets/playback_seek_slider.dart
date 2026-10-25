import 'package:flutter/material.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/utils/playback_seek_preview.dart';
import 'package:mosix/widgets/expressive_seek_track.dart';
import 'package:mosix/widgets/mornye_player_slider.dart';

/// Previews scrubbing locally and seeks once when the gesture ends.
class PlaybackSeekSlider extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Future<void> Function(Duration) onSeek;
  final PlaybackSeekPreview? preview;
  final bool playing;

  const PlaybackSeekSlider({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.preview,
    this.playing = false,
  });

  @override
  State<PlaybackSeekSlider> createState() => _PlaybackSeekSliderState();
}

class _PlaybackSeekSliderState extends State<PlaybackSeekSlider> {
  double? _previewMs;
  int _gestureGeneration = 0;
  Object? _previewSession;

  void _start(double value) {
    _gestureGeneration++;
    _previewSession = widget.preview?.begin(
      Duration(milliseconds: value.round()),
    );
  }

  void _preview(double value) {
    setState(() => _previewMs = value);
    final session = _previewSession;
    if (session != null) {
      widget.preview?.update(session, Duration(milliseconds: value.round()));
    }
  }

  Future<void> _adjust(double value) {
    _start(value);
    _preview(value);
    return _commit(value);
  }

  Future<void> _commit(double value) async {
    final generation = _gestureGeneration;
    final preview = widget.preview;
    final session = _previewSession;
    try {
      await widget.onSeek(Duration(milliseconds: value.round()));
    } finally {
      preview?.end(session);
      if (mounted && generation == _gestureGeneration) {
        setState(() => _previewMs = null);
      }
    }
  }

  @override
  void dispose() {
    final preview = widget.preview;
    final session = _previewSession;
    // Rotation or track replacement can remove this slider during layout.
    // Notify surviving lyrics/time labels after that frame has finished.
    WidgetsBinding.instance.addPostFrameCallback((_) => preview?.end(session));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.duration.inMilliseconds;
    final enabled = durationMs > 0;
    final maxMs = enabled ? durationMs.toDouble() : 1.0;
    if (context.isMornye) {
      final currentMs = (_previewMs ?? widget.position.inMilliseconds)
          .clamp(0, maxMs)
          .toDouble();
      String percentage(double milliseconds) =>
          '${(milliseconds / maxMs * 100).clamp(0, 100).round()}%';
      return LayoutBuilder(
        builder: (context, constraints) => Semantics(
          slider: true,
          enabled: enabled,
          excludeSemantics: true,
          value: percentage(currentMs),
          increasedValue: enabled
              ? percentage((currentMs + 5000).clamp(0, maxMs).toDouble())
              : null,
          decreasedValue: enabled
              ? percentage((currentMs - 5000).clamp(0, maxMs).toDouble())
              : null,
          onIncrease: enabled
              ? () => _adjust((currentMs + 5000).clamp(0, maxMs).toDouble())
              : null,
          onDecrease: enabled
              ? () => _adjust((currentMs - 5000).clamp(0, maxMs).toDouble())
              : null,
          child: IgnorePointer(
            ignoring: !enabled,
            child: MornyePlayerSlider(
              activeColor:
                  SliderTheme.of(context).activeTrackColor ?? Colors.white,
              inactiveColor:
                  SliderTheme.of(context).inactiveTrackColor ?? Colors.white12,
              value: enabled ? currentMs : 0,
              max: maxMs,
              onChangeStart: _start,
              onChanged: _preview,
              onChangeEnd: _commit,
            ),
          ),
        ),
      );
    }
    return ExpressiveSeekTrack(
      playing:
          widget.playing &&
          enabled &&
          widget.position < widget.duration &&
          _previewMs == null,
      child: Slider(
        value: enabled
            ? (_previewMs ?? widget.position.inMilliseconds.toDouble()).clamp(
                0,
                maxMs,
              )
            : 0,
        max: maxMs,
        onChangeStart: enabled ? _start : null,
        onChanged: enabled ? _preview : null,
        onChangeEnd: enabled ? _commit : null,
      ),
    );
  }
}
