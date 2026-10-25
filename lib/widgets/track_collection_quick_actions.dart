import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:flutter/services.dart';
import 'package:mosix/widgets/app_bottom_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/track.dart';
import 'package:mosix/providers/library_collections_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/services/cover_cache_manager.dart';
import 'package:mosix/utils/local_playback.dart';
import 'package:mosix/widgets/playlist_picker_sheet.dart';
import 'package:mosix/widgets/mornye_context_menu.dart';
import 'package:share_plus/share_plus.dart';
import 'package:mosix/widgets/track_collection_action_policy.dart';
import 'package:mosix/widgets/track_detail_actions.dart';
import 'package:mosix/utils/clickable_metadata.dart';

class TrackCollectionQuickActions extends ConsumerWidget {
  final Track track;
  final bool hasLocalPlaybackCandidate;

  const TrackCollectionQuickActions({
    super.key,
    required this.track,
    this.hasLocalPlaybackCandidate = false,
  });

  static void showTrackOptionsSheet(
    BuildContext context,
    WidgetRef ref,
    Track track, {
    bool hasLocalPlaybackCandidate = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    if (context.isMornye) {
      showMornyeContextMenu<void>(
        context: context,
        builder: (_) => _TrackOptionsSheet(
          track: track,
          hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (_) => _TrackOptionsSheet(
        track: track,
        hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    return IconButton(
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      icon: Icon(
        context.isMornye ? CupertinoIcons.ellipsis : Icons.more_vert,
        color: colorScheme.onSurfaceVariant,
        size: 20,
      ),
      onPressed: () => showTrackOptionsSheet(
        context,
        ref,
        track,
        hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }
}

class _TrackOptionsSheet extends ConsumerWidget {
  final Track track;
  final bool hasLocalPlaybackCandidate;

  const _TrackOptionsSheet({
    required this.track,
    required this.hasLocalPlaybackCandidate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    final isLoved = ref.watch(
      libraryCollectionsProvider.select((state) => state.isLoved(track)),
    );
    final isInWishlist = ref.watch(
      libraryCollectionsProvider.select((state) => state.isInWishlist(track)),
    );
    final allowQualityVariants = ref.watch(
      settingsProvider.select((settings) => settings.allowQualityVariants),
    );
    final qualityVariantAction = resolveQualityVariantMenuAction(
      allowQualityVariants: allowQualityVariants,
      hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
    );

    if (context.isMornye) {
      final l10n = context.l10n;
      return MornyeContextMenu(
        quickActions: [
          MornyeMenuAction(
            icon: CupertinoIcons.arrow_down_circle_fill,
            label: l10n.dialogDownload,
            onPressed: () {
              final root = Navigator.of(context, rootNavigator: true).context;
              Navigator.pop(context);
              downloadSingleTrack(root, ref, track);
            },
          ),
          MornyeMenuAction(
            icon: CupertinoIcons.star_fill,
            label: isLoved ? l10n.mornyeFavorited : l10n.mornyeFavorite,
            selected: isLoved,
            onPressed: () => _toggleCollection(context, ref, wishlist: false),
          ),
          MornyeMenuAction(
            icon: CupertinoIcons.share_solid,
            label: l10n.trackMetadataShare,
            onPressed: () {
              final origin =
                  mornyeMenuAnchor(context) ??
                  Rect.fromCenter(
                    center: MediaQuery.sizeOf(context).center(Offset.zero),
                    width: 1,
                    height: 1,
                  );
              Navigator.pop(context);
              SharePlus.instance.share(
                ShareParams(
                  text: '${track.name} — ${track.artistName}',
                  sharePositionOrigin: origin,
                ),
              );
            },
          ),
        ],
        groups: [
          [
            if (qualityVariantAction == QualityVariantMenuAction.playLocal)
              MornyeMenuAction(
                icon: CupertinoIcons.play,
                label: l10n.trackMetadataPlay,
                onPressed: () => _playLocal(context, ref),
              ),
            if (qualityVariantAction ==
                QualityVariantMenuAction.downloadAnotherQuality)
              MornyeMenuAction(
                icon: CupertinoIcons.arrow_down_circle,
                label: l10n.trackOptionDownloadQualityVariant,
                onPressed: () => _downloadQualityVariant(context, ref),
              ),
            MornyeMenuAction(
              icon: CupertinoIcons.square_stack,
              label: l10n.homeGoToAlbum,
              onPressed: () => _goToAlbum(context),
            ),
          ],
          [
            MornyeMenuAction(
              icon: CupertinoIcons.text_badge_plus,
              label: l10n.collectionAddToPlaylist,
              onPressed: () {
                final root = Navigator.of(context, rootNavigator: true).context;
                Navigator.pop(context);
                showAddTrackToPlaylistSheet(root, ref, track);
              },
            ),
            MornyeMenuAction(
              icon: isInWishlist
                  ? CupertinoIcons.checkmark_circle
                  : CupertinoIcons.add_circled,
              label: isInWishlist
                  ? l10n.trackOptionRemoveFromWishlist
                  : l10n.trackOptionAddToWishlist,
              onPressed: () => _toggleCollection(context, ref, wishlist: true),
            ),
          ],
          [
            MornyeMenuAction(
              icon: CupertinoIcons.doc_on_doc,
              label: l10n.trackOptionCopyTrackName,
              onPressed: () => _copyText(context, track.name),
            ),
            MornyeMenuAction(
              icon: CupertinoIcons.person,
              label: l10n.trackOptionCopyArtist,
              onPressed: () => _copyText(context, track.artistName),
            ),
            MornyeMenuAction(
              icon: CupertinoIcons.doc_on_doc,
              label: l10n.trackOptionCopyTrackAndArtist,
              onPressed: () =>
                  _copyText(context, '${track.name} - ${track.artistName}'),
            ),
          ],
        ],
      );
    }

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                children: [
                  const AppSheetHandle(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child:
                              track.coverUrl != null &&
                                  track.coverUrl!.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: track.coverUrl!,
                                  width: 56,
                                  height: 56,
                                  fit: BoxFit.cover,
                                  memCacheWidth: 112,
                                  cacheManager: CoverCacheManager.instance,
                                  errorWidget: (context, url, error) =>
                                      Container(
                                        width: 56,
                                        height: 56,
                                        color:
                                            colorScheme.surfaceContainerHighest,
                                        child: Icon(
                                          Icons.music_note,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                )
                              : Container(
                                  width: 56,
                                  height: 56,
                                  color: colorScheme.surfaceContainerHighest,
                                  child: Icon(
                                    Icons.music_note,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track.name,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              ClickableArtistName(
                                artistName: track.artistName,
                                artistId: track.artistId,
                                coverUrl: track.coverUrl,
                                extensionId: track.source,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Divider(
                height: 1,
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),

              if (qualityVariantAction == QualityVariantMenuAction.playLocal)
                _OptionTile(
                  icon: Icons.play_arrow_rounded,
                  title: context.l10n.trackMetadataPlay,
                  onTap: () => _playLocal(context, ref),
                )
              else if (qualityVariantAction ==
                  QualityVariantMenuAction.downloadAnotherQuality)
                _OptionTile(
                  icon: Icons.download_outlined,
                  title: context.l10n.trackOptionDownloadQualityVariant,
                  onTap: () => _downloadQualityVariant(context, ref),
                ),

              _OptionTile(
                icon: Icons.content_copy_rounded,
                title: context.l10n.trackOptionCopyTrackName,
                onTap: () => _copyText(context, track.name),
              ),
              _OptionTile(
                icon: Icons.person_outline_rounded,
                title: context.l10n.trackOptionCopyArtist,
                onTap: () => _copyText(context, track.artistName),
              ),
              _OptionTile(
                icon: Icons.copy_all_rounded,
                title: context.l10n.trackOptionCopyTrackAndArtist,
                onTap: () =>
                    _copyText(context, '${track.name} - ${track.artistName}'),
              ),

              _OptionTile(
                icon: Icons.album_outlined,
                title: context.l10n.homeGoToAlbum,
                onTap: () => _goToAlbum(context),
              ),

              _OptionTile(
                icon: isLoved ? Icons.favorite : Icons.favorite_border,
                iconColor: isLoved ? colorScheme.error : null,
                title: isLoved
                    ? context.l10n.trackOptionRemoveFromLoved
                    : context.l10n.trackOptionAddToLoved,
                onTap: () async {
                  Navigator.pop(context);
                  final added = await ref
                      .read(libraryCollectionsProvider.notifier)
                      .toggleLoved(track);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        added
                            ? context.l10n.collectionAddedToLoved(track.name)
                            : context.l10n.collectionRemovedFromLoved(
                                track.name,
                              ),
                      ),
                    ),
                  );
                },
              ),
              _OptionTile(
                icon: isInWishlist
                    ? Icons.playlist_add_check_circle
                    : Icons.add_circle_outline,
                iconColor: isInWishlist ? colorScheme.primary : null,
                title: isInWishlist
                    ? context.l10n.trackOptionRemoveFromWishlist
                    : context.l10n.trackOptionAddToWishlist,
                onTap: () async {
                  Navigator.pop(context);
                  final added = await ref
                      .read(libraryCollectionsProvider.notifier)
                      .toggleWishlist(track);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        added
                            ? context.l10n.collectionAddedToWishlist(track.name)
                            : context.l10n.collectionRemovedFromWishlist(
                                track.name,
                              ),
                      ),
                    ),
                  );
                },
              ),
              _OptionTile(
                icon: Icons.playlist_add,
                title: context.l10n.collectionAddToPlaylist,
                onTap: () {
                  final rootContext = Navigator.of(
                    context,
                    rootNavigator: true,
                  ).context;
                  Navigator.pop(context);
                  showAddTrackToPlaylistSheet(rootContext, ref, track);
                },
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _downloadQualityVariant(BuildContext context, WidgetRef ref) {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    downloadSingleTrack(rootContext, ref, track, forceQualityPicker: true);
  }

  Future<void> _toggleCollection(
    BuildContext context,
    WidgetRef ref, {
    required bool wishlist,
  }) async {
    final root = Navigator.of(context, rootNavigator: true).context;
    final notifier = ref.read(libraryCollectionsProvider.notifier);
    Navigator.pop(context);
    final added = wishlist
        ? await notifier.toggleWishlist(track)
        : await notifier.toggleLoved(track);
    if (!root.mounted) return;
    final l10n = root.l10n;
    final message = wishlist
        ? (added
              ? l10n.collectionAddedToWishlist(track.name)
              : l10n.collectionRemovedFromWishlist(track.name))
        : (added
              ? l10n.collectionAddedToLoved(track.name)
              : l10n.collectionRemovedFromLoved(track.name));
    ScaffoldMessenger.of(root).showSnackBar(SnackBar(content: Text(message)));
  }

  void _copyText(BuildContext context, String text) {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(rootContext).showSnackBar(
      SnackBar(content: Text(rootContext.l10n.trackCopiedToClipboard)),
    );
  }

  Future<void> _goToAlbum(BuildContext context) async {
    final navigationContext = Navigator.of(
      context,
      rootNavigator: true,
    ).context;
    Navigator.pop(context);
    await navigateToTrackAlbum(navigationContext, track);
  }

  Future<void> _playLocal(BuildContext context, WidgetRef ref) async {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    final played = await playLocalIfAvailable(rootContext, ref, track);
    if (!played && rootContext.mounted) {
      ScaffoldMessenger.of(rootContext).showSnackBar(
        SnackBar(content: Text(rootContext.l10n.snackbarFileNotFound)),
      );
    }
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final VoidCallback onTap;

  const _OptionTile({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          icon,
          color: iconColor ?? colorScheme.onPrimaryContainer,
          size: 20,
        ),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      onTap: onTap,
    );
  }
}
