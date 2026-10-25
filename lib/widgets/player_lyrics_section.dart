import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/controllers/player_metadata_controller.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/utils/playback_seek_preview.dart';
import 'package:mosix/widgets/app_loading_indicator.dart';
import 'package:mosix/widgets/player_lyrics.dart';
import 'package:mosix/widgets/lyrics_text_scale.dart';

class PlayerLyricsSection extends ConsumerWidget {
  const PlayerLyricsSection({
    super.key,
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    required this.isActive,
    this.options,
  });

  final PlayerMetadataController metadata;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final bool isActive;
  final Widget? options;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibility = ref.watch(
      settingsProvider.select(
        (settings) =>
            (settings.playerShowPronunciation, settings.playerShowTranslation),
      ),
    );
    return ListenableBuilder(
      listenable: metadata,
      builder: (context, _) => _buildLyricsSection(context, visibility),
    );
  }

  Widget _buildLyricsSection(BuildContext context, (bool, bool) visibility) {
    if (metadata.loading) {
      return const Center(child: AppLoadingIndicator());
    }
    if (metadata.lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lyrics_outlined,
              size: 40,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.nowPlayingNoLyrics,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    if (metadata.lyrics.synced) {
      return Stack(
        fit: StackFit.expand,
        children: [
          SyncedLyricsView(
            lyrics: metadata.lyrics,
            seekPreview: seekPreview,
            credits: _lyricsCredits(),
            colorScheme: colorScheme,
            isActive: isActive,
            showPronunciation: visibility.$1,
            showTranslation: visibility.$2,
          ),
          if (options != null)
            Positioned(
              left: context.isMornye ? mornyeLyricsContentInset : 24,
              bottom: 8,
              child: options!,
            ),
        ],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LyricsTextScale(
            child: Text(
              metadata.lyrics.plainText,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                height: 1.6,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          ?_lyricsCredits(),
        ],
      ),
    );
  }

  LyricsCredits? _lyricsCredits() {
    final (:writers, :provider) = metadata.credits;
    if (writers == null && provider == null) return null;
    return LyricsCredits(writers: writers, provider: provider);
  }
}
