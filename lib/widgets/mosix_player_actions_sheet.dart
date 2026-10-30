import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/library_collections_provider.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/theme/cover_palette.dart';
import 'package:mosix/theme/mosix_theme.dart';
import 'package:mosix/widgets/mosix_context_menu.dart';

/// Navigation for the title/artist, separate from playback and file actions.
class MosixPlayerNavigationMenu extends StatelessWidget {
  const MosixPlayerNavigationMenu({super.key, required this.mediaItem});

  final MediaItem mediaItem;

  @override
  Widget build(BuildContext context) {
    return _MosixPlayerMenuSurface(
      mediaItem: mediaItem,
      child: MosixContextMenu(
        inheritSurface: true,
        dense: true,
        groups: [
          [
            if ((mediaItem.artist ?? '').trim().isNotEmpty)
              MosixMenuAction(
                icon: CupertinoIcons.mic,
                label: context.l10n.mosixGoToArtist,
                subtitle: mediaItem.artist,
                onPressed: () => Navigator.of(context).pop('artist'),
              ),
            if ((mediaItem.album ?? '').trim().isNotEmpty)
              MosixMenuAction(
                icon: CupertinoIcons.square_stack,
                label: context.l10n.homeGoToAlbum,
                subtitle: mediaItem.album,
                onPressed: () => Navigator.of(context).pop('album'),
              ),
          ],
        ],
      ),
    );
  }
}

/// A floating menu that inherits the player's dark appearance.
class MosixPlayerActionsSheet extends ConsumerWidget {
  const MosixPlayerActionsSheet({
    super.key,
    required this.mediaItem,
    this.sleepTimerSubtitle,
  });

  final MediaItem mediaItem;
  final String? sleepTimerSubtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerCollectionTrackProvider(mediaItem)).value;
    final loved = ref.watch(
      libraryCollectionsProvider.select(
        (state) => track != null && state.isLoved(track),
      ),
    );
    return _MosixPlayerMenuSurface(
      mediaItem: mediaItem,
      child: MosixContextMenu(
        inheritSurface: true,
        dense: true,
        quickActions: [
          _action(
            context,
            'favorite',
            loved ? context.l10n.mosixFavorited : context.l10n.mosixFavorite,
            CupertinoIcons.star_fill,
            selected: loved,
          ),
          _action(
            context,
            'share',
            context.l10n.trackMetadataShare,
            CupertinoIcons.share_solid,
          ),
        ],
        groups: [
          [
            _action(
              context,
              'playlist',
              context.l10n.collectionAddToPlaylist,
              CupertinoIcons.text_badge_plus,
            ),
          ],
          [
            if ((mediaItem.album ?? '').trim().isNotEmpty)
              _action(
                context,
                'album',
                context.l10n.homeGoToAlbum,
                CupertinoIcons.square_stack,
                subtitle: mediaItem.album,
              ),
            if ((mediaItem.artist ?? '').trim().isNotEmpty)
              _action(
                context,
                'artist',
                context.l10n.mosixGoToArtist,
                CupertinoIcons.mic,
                subtitle: mediaItem.artist,
              ),
            _action(
              context,
              'details',
              context.l10n.nowPlayingDetails,
              CupertinoIcons.info,
            ),
            _action(
              context,
              'shareLyrics',
              context.l10n.lyricsShareTitle,
              CupertinoIcons.quote_bubble,
            ),
          ],
          [
            _action(
              context,
              'equalizer',
              context.l10n.equalizerTitle,
              CupertinoIcons.slider_horizontal_3,
            ),
            _action(
              context,
              'sleepTimer',
              context.l10n.nowPlayingSleepTimer,
              CupertinoIcons.moon_zzz,
              subtitle: sleepTimerSubtitle,
            ),
            _action(
              context,
              'external',
              context.l10n.nowPlayingOpenInExternalPlayer,
              CupertinoIcons.arrow_up_right_square,
            ),
          ],
        ],
      ),
    );
  }

  MosixMenuAction _action(
    BuildContext context,
    String value,
    String label,
    IconData icon, {
    String? subtitle,
    bool selected = false,
  }) => MosixMenuAction(
    icon: icon,
    label: label,
    subtitle: subtitle,
    selected: selected,
    onPressed: () => Navigator.of(context).pop(value),
  );
}

/// Reuse the cached cover palette; no per-frame background capture is needed.
class _MosixPlayerMenuSurface extends StatelessWidget {
  const _MosixPlayerMenuSurface({
    required this.mediaItem,
    required this.child,
  });

  final MediaItem mediaItem;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final art = mediaItem.artUri;
    final source = art?.scheme == 'file' ? art!.toFilePath() : art?.toString();
    return CoverPaletteBuilder(
      imageSource: source,
      builder: (context, _) {
        final dominant = HSLColor.fromColor(
          source == null
              ? Colors.grey
              : CoverPalette.sourceColor(source, Brightness.dark) ??
                    Colors.grey,
        );
        final surface = dominant
            .withSaturation(dominant.saturation.clamp(0.0, 0.34))
            .withLightness(0.28)
            .toColor();
        return Theme(
          data: MosixTheme.fromContext(
            context,
            brightness: Brightness.dark,
            chromeSurface: surface,
          ),
          child: child,
        );
      },
    );
  }
}
