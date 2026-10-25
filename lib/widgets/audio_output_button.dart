import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/app_icon_button.dart';

/// Uses the system's real audio routes and keeps native discovery in native UI.
class AudioOutputButton extends StatefulWidget {
  const AudioOutputButton({super.key, this.color, this.onPickerChanged});

  final Color? color;
  final ValueChanged<bool>? onPickerChanged;

  @override
  State<AudioOutputButton> createState() => _AudioOutputButtonState();
}

class _AudioOutputButtonState extends State<AudioOutputButton> {
  static const _androidChannel = MethodChannel('com.zarz.mornye/audio_output');
  MethodChannel? _viewChannel;
  bool _opening = false;

  Map<String, Object> get _appearance => {
    'color': (widget.color ?? Theme.of(context).colorScheme.onSurface)
        .toARGB32(),
    'label': context.l10n.nowPlayingAudioOutput,
  };

  @override
  void didUpdateWidget(AudioOutputButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAppearance();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAppearance();
  }

  void _updateAppearance() {
    final channel = _viewChannel;
    if (channel != null) {
      unawaited(channel.invokeMethod<void>('update', _appearance));
    }
  }

  void _attachView(int id) {
    _viewChannel?.setMethodCallHandler(null);
    _viewChannel = MethodChannel('com.zarz.mornye/audio_output/$id')
      ..setMethodCallHandler((call) async {
        if (mounted && call.method == 'pickerChanged') {
          widget.onPickerChanged?.call(call.arguments == true);
        }
      });
    _updateAppearance();
  }

  Future<void> _showAndroidPicker() async {
    if (_opening) return;
    _opening = true;
    widget.onPickerChanged?.call(true);
    var opened = false;
    try {
      opened = await _androidChannel.invokeMethod<bool>('show') ?? false;
    } on PlatformException {
      // Show a visible failure instead of leaving an unresponsive control.
    } on MissingPluginException {
      // The native bridge is not available on unsupported builds.
    } finally {
      _opening = false;
      if (mounted) widget.onPickerChanged?.call(false);
    }
    if (mounted && !opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.nowPlayingAudioOutputUnavailable)),
      );
    }
  }

  @override
  void dispose() {
    _viewChannel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return SizedBox.square(
          dimension: 48,
          child: UiKitView(
            viewType: 'com.zarz.mornye/audio_output',
            creationParams: _appearance,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _attachView,
          ),
        );
      case TargetPlatform.android:
        return AppIconButton(
          tooltip: context.l10n.nowPlayingAudioOutput,
          color: widget.color,
          icon: const Icon(Icons.speaker_group_outlined),
          onPressed: _showAndroidPicker,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
