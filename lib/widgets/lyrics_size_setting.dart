import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/theme_provider.dart';
import 'package:mosix/widgets/lyrics_text_scale.dart';

class LyricsSizeSetting extends ConsumerWidget {
  const LyricsSizeSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(
      themeProvider.select((theme) => theme.lyricsTextScale),
    );
    final notifier = ref.read(themeProvider.notifier);
    final percent = '${(scale * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.lyricsTextSize,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(percent),
              IconButton(
                tooltip: context.l10n.libraryFilterReset,
                onPressed: scale == 1
                    ? null
                    : () => notifier.setLyricsTextScale(1),
                icon: const Icon(Icons.restart_alt),
              ),
            ],
          ),
          LyricsTextScale(
            child: Text(
              context.l10n.lyricsTextPreview,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          Slider(
            value: scale,
            min: 0.8,
            max: 1.4,
            divisions: 12,
            label: percent,
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
