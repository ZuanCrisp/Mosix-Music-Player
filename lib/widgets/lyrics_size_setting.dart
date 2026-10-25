import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/lyrics_text_scale.dart';
import 'package:mornye/widgets/slider_value_header.dart';

class LyricsSizeSetting extends ConsumerWidget {
  const LyricsSizeSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(
      themeProvider.select((theme) => theme.lyricsTextScale),
    );
    final notifier = ref.read(themeProvider.notifier);
    final percent = '${(scale * 100).round()}%';
    final reset = AppIconButton(
      tooltip: context.l10n.libraryFilterReset,
      onPressed: scale == 1 ? null : () => notifier.setLyricsTextScale(1),
      icon: const Icon(Icons.restart_alt),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (context.isMornye)
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.lyricsTextSize,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(percent),
                reset,
              ],
            )
          else
            SliderValueHeader(
              title: context.l10n.lyricsTextSize,
              value: percent,
              trailing: reset,
            ),
          LyricsTextScale(
            child: Text(
              context.l10n.lyricsTextPreview,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          AppSlider(
            value: scale,
            min: 0.8,
            max: 1.4,
            divisions: 12,
            label: percent,
            semanticLabel: context.l10n.lyricsTextSize,
            semanticFormatterCallback: (value) => '${(value * 100).round()}%',
            onChanged: (value) =>
                notifier.setLyricsTextScale(value, persist: false),
            onChangeEnd: notifier.setLyricsTextScale,
          ),
        ],
      ),
    );
  }
}
