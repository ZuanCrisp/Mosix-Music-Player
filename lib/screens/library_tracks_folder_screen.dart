import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:mosix/widgets/collection_scaffold.dart';
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/widgets/track_card.dart';
import 'package:mosix/widgets/app_bottom_sheet.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';
import 'package:mosix/widgets/app_snack_bar.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/theme/mornye_icons.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus, XFile;
import 'package:mosix/widgets/album_detail_header.dart';
import 'package:mosix/widgets/cached_cover_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/track.dart';
import 'package:mosix/services/m3u_playlist_service.dart';
import 'package:mosix/services/downloaded_embedded_cover_resolver.dart';
import 'package:mosix/utils/file_access.dart';
import 'package:mosix/providers/download_queue_provider.dart';
import 'package:mosix/providers/extension_provider.dart';
import 'package:mosix/providers/library_collections_provider.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/playback_provider.dart';
import 'package:mosix/providers/local_library_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/utils/adaptive_layout.dart';
import 'package:mosix/utils/cover_art_utils.dart';
import 'package:mosix/screens/collapsing_header_scroll_mixin.dart';
import 'package:mosix/screens/selection_mode_mixin.dart';
import 'package:mosix/screens/library_tracks_folder_data.dart';
import 'package:mosix/screens/track_metadata_screen.dart';
import 'package:mosix/widgets/selection_action_button.dart';
import 'package:mosix/widgets/selection_bottom_bar.dart';
import 'package:mosix/widgets/in_library_badge.dart';
import 'package:mosix/widgets/playlist_picker_sheet.dart';
import 'package:mosix/widgets/animation_utils.dart';
import 'package:mosix/widgets/track_detail_actions.dart';

String? _resolveRawCoverUrl(Track track) {
  final rawCover = track.coverUrl?.trim();
  if (rawCover != null &&
      rawCover.isNotEmpty &&
      !rawCover.startsWith('content://')) {
    return rawCover;
  }
  return null;
}

class LibraryTracksFolderScreen extends ConsumerStatefulWidget {
  final LibraryTracksFolderMode mode;
  final String? playlistId;

  const LibraryTracksFolderScreen({
    super.key,
    required this.mode,
    this.playlistId,
  });

  @override
  ConsumerState<LibraryTracksFolderScreen> createState() =>
      _LibraryTracksFolderScreenState();
}

class _LibraryTracksFolderScreenState
    extends ConsumerState<LibraryTracksFolderScreen>
    with
        SelectionModeMixin<LibraryTracksFolderScreen>,
        CollapsingHeaderScrollMixin<LibraryTracksFolderScreen> {
  UserPlaylistCollection? playlist;
  final _folderData = LibraryTracksFolderData();

  @override
  void initState() {
    super.initState();
    final playlistId = widget.playlistId;
    if (widget.mode == LibraryTracksFolderMode.playlist && playlistId != null) {
      Future.microtask(
        () => ref
            .read(libraryCollectionsProvider.notifier)
            .ensurePlaylistLoaded(playlistId),
      );
    }
  }

  /// Exports the collection as an .m3u8 shared via the system sheet. Tracks
  /// without a resolvable local file are skipped; SAF entries are written
  /// relative to the download tree root.
  Future<void> _exportAsM3u8(
    BuildContext context,
    String title,
    List<CollectionTrackEntry> entries,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final tracks = entries.map((e) => e.track).toList(growable: false);
      final paths = await ref
          .read(playbackProvider.notifier)
          .resolveTrackFilePaths(tracks);

      final exportEntries = <M3uExportEntry>[];
      for (var i = 0; i < tracks.length; i++) {
        final path = paths[i];
        if (path == null || isCueVirtualPath(path)) continue;
        final entryPath = M3uPlaylistService.exportPathFor(path);
        if (entryPath == null) continue;
        exportEntries.add(M3uExportEntry(track: tracks[i], path: entryPath));
      }

      if (exportEntries.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.collectionExportM3uNone)),
        );
        return;
      }

      final file = await M3uPlaylistService.writeExportEntries(
        title,
        exportEntries,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.collectionExportM3uDone(exportEntries.length, tracks.length),
          ),
        ),
      );
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: title),
      );
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.collectionExportM3uFailed)),
      );
    }
  }

  IconData _modeIcon() {
    return switch (widget.mode) {
      LibraryTracksFolderMode.wishlist => Icons.bookmark,
      LibraryTracksFolderMode.loved => Icons.favorite,
      LibraryTracksFolderMode.playlist => Icons.queue_music,
    };
  }

  /// Find the first available cover URL from entries.
  String? _firstRawCoverUrl(List<CollectionTrackEntry> entries) {
    for (final entry in entries) {
      final cover = _resolveRawCoverUrl(entry.track);
      if (cover != null && cover.isNotEmpty) {
        return cover;
      }
    }
    return null;
  }

  Future<void> _removeSelected(List<CollectionTrackEntry> entries) async {
    final keysToRemove = selectedIds.toSet();
    if (keysToRemove.isEmpty) return;

    final count = keysToRemove.length;
    final notifier = ref.read(libraryCollectionsProvider.notifier);

    switch (widget.mode) {
      case LibraryTracksFolderMode.wishlist:
        await notifier.removeWishlistTracks(keysToRemove);
        break;
      case LibraryTracksFolderMode.loved:
        await notifier.removeLovedTracks(keysToRemove);
        break;
      case LibraryTracksFolderMode.playlist:
        if (widget.playlistId != null) {
          await notifier.removeTracksFromPlaylist(
            widget.playlistId!,
            keysToRemove,
          );
        }
        break;
    }

    exitSelectionMode();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.selectionSelected(count))),
    );
  }

  LocalLibraryCoverBatchRequest _coverBatchRequest(
    List<CollectionTrackEntry> entries,
  ) {
    return LocalLibraryCoverBatchRequest(
      entries
          .map(
            (entry) => LocalLibraryCoverRequest(
              isrc: entry.track.isrc?.trim(),
              trackName: entry.track.name,
              artistName: entry.track.artistName,
            ),
          )
          .toList(growable: false),
    );
  }

  void _downloadSelected(List<CollectionTrackEntry> entries) {
    final settings = ref.read(settingsProvider);
    final extensionState = ref.read(extensionProvider);
    final service = resolveEffectiveDownloadService(
      settings.defaultService,
      extensionState,
    );
    if (service.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
      );
      return;
    }
    final queueNotifier = ref.read(downloadQueueProvider.notifier);
    final tracks = entries
        .where((entry) => selectedIds.contains(entry.key))
        .map((entry) => entry.track)
        .toList(growable: false);
    queueNotifier.addIndividualTracksToQueue(tracks, service);
    final count = tracks.length;

    exitSelectionMode();

    if (!mounted || count == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.selectionSelected(count))),
    );
  }

  void _addSelectedToPlaylist(List<CollectionTrackEntry> entries) {
    final selectedTracks = entries
        .where((e) => selectedIds.contains(e.key))
        .map((e) => e.track)
        .toList(growable: false);
    if (selectedTracks.isEmpty) return;

    showAddTracksToPlaylistSheet(context, ref, selectedTracks);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
    final List<CollectionTrackEntry> entries;

    switch (widget.mode) {
      case LibraryTracksFolderMode.wishlist:
        playlist = null;
        entries = ref.watch(
          libraryCollectionsProvider.select((state) => state.wishlist),
        );
        break;
      case LibraryTracksFolderMode.loved:
        playlist = null;
        entries = ref.watch(
          libraryCollectionsProvider.select((state) => state.loved),
        );
        break;
      case LibraryTracksFolderMode.playlist:
        final playlistId = widget.playlistId;
        playlist = playlistId == null
            ? null
            : ref.watch(
                libraryCollectionsProvider.select(
                  (state) => state.playlistById(playlistId),
                ),
              );
        entries = playlist?.tracks ?? const <CollectionTrackEntry>[];
        break;
    }

    _folderData.update(entries);
    pruneSelection(_folderData.keys);

    final title = switch (widget.mode) {
      LibraryTracksFolderMode.wishlist => context.l10n.collectionWishlist,
      LibraryTracksFolderMode.loved => context.l10n.collectionLoved,
      LibraryTracksFolderMode.playlist =>
        playlist?.name ?? context.l10n.collectionPlaylist,
    };

    final emptyTitle = switch (widget.mode) {
      LibraryTracksFolderMode.wishlist =>
        context.l10n.collectionWishlistEmptyTitle,
      LibraryTracksFolderMode.loved => context.l10n.collectionLovedEmptyTitle,
      LibraryTracksFolderMode.playlist =>
        context.l10n.collectionPlaylistEmptyTitle,
    };

    final emptySubtitle = switch (widget.mode) {
      LibraryTracksFolderMode.wishlist =>
        context.l10n.collectionWishlistEmptySubtitle,
      LibraryTracksFolderMode.loved =>
        context.l10n.collectionLovedEmptySubtitle,
      LibraryTracksFolderMode.playlist =>
        context.l10n.collectionPlaylistEmptySubtitle,
    };
    final folderTracks = _folderData.tracks;
    final historyLookups = _folderData.historyRequest.tracks;
    final existingHistoryKeys = ref.watch(
      downloadHistoryVisibleBatchExistsProvider(_folderData.historyRequest),
    );

    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;

    return CollectionScaffold(
      scrollController: scrollController,
      isSelectionMode: isSelectionMode,
      onExitSelectionMode: exitSelectionMode,
      selectionBar: _buildSelectionBottomBar(
        context,
        colorScheme,
        entries,
        bottomPadding,
      ),
      appBar: _buildAppBar(context, colorScheme, title, entries, playlist),
      slivers: [
        if (entries.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyFolderState(
              title: emptyTitle,
              subtitle: emptySubtitle,
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final entry = entries[index];
                final isSelected = selectedIds.contains(entry.key);
                final isInHistory = existingHistoryKeys.contains(
                  historyLookups[index].lookupKey,
                );
                return KeyedSubtree(
                  key: ValueKey(entry.key),
                  child: StaggeredListItem(
                    index: index,
                    child: _CollectionTrackTile(
                      entry: entry,
                      mode: widget.mode,
                      playlistId: widget.playlistId,
                      folderTracks: folderTracks,
                      trackIndex: index,
                      isInHistory: isInHistory,
                      isSelectionMode: isSelectionMode,
                      isSelected: isSelected,
                      onTap: isSelectionMode
                          ? () => toggleSelection(entry.key)
                          : null,
                      onLongPress: isSelectionMode
                          ? null
                          : () => enterSelectionMode(entry.key),
                    ),
                  ),
                );
              }, childCount: entries.length),
            ),
          ),
      ],
    );
  }

  Widget _buildSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<CollectionTrackEntry> entries,
    double bottomPadding,
  ) {
    final selectedCount = selectedIds.length;
    final allSelected = selectedCount == entries.length && entries.isNotEmpty;
    final isWishlist = widget.mode == LibraryTracksFolderMode.wishlist;

    return SelectionBottomBar(
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: exitSelectionMode,
      onToggleSelectAll: () {
        if (allSelected) {
          exitSelectionMode();
        } else {
          selectAll(entries.map((e) => e.key));
        }
      },
      bottomPadding: bottomPadding,
      children: [
        Row(
          children: [
            if (isWishlist)
              Expanded(
                child: SelectionActionButton(
                  icon: Icons.download,
                  label: '${context.l10n.settingsDownload} ($selectedCount)',
                  onPressed: selectedCount > 0
                      ? () => _downloadSelected(entries)
                      : null,
                  colorScheme: colorScheme,
                ),
              ),
            if (isWishlist) const SizedBox(width: 8),
            Expanded(
              child: SelectionActionButton(
                icon: Icons.playlist_add,
                label:
                    '${context.l10n.collectionAddToPlaylist} ($selectedCount)',
                onPressed: selectedCount > 0
                    ? () => _addSelectedToPlaylist(entries)
                    : null,
                colorScheme: colorScheme,
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: selectedCount > 0
                ? () => _removeSelected(entries)
                : null,
            icon: const Icon(Icons.remove_circle_outline),
            label: Text(
              selectedCount > 0
                  ? '${widget.mode == LibraryTracksFolderMode.playlist ? context.l10n.collectionRemoveFromPlaylist : context.l10n.collectionRemoveFromFolder} ($selectedCount)'
                  : widget.mode == LibraryTracksFolderMode.playlist
                  ? context.l10n.collectionRemoveFromPlaylist
                  : context.l10n.collectionRemoveFromFolder,
            ),
            style: FilledButton.styleFrom(
              backgroundColor: selectedCount > 0
                  ? colorScheme.error
                  : colorScheme.surfaceContainerHighest,
              foregroundColor: selectedCount > 0
                  ? colorScheme.onError
                  : colorScheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickCoverImage() async {
    final playlistId = widget.playlistId;
    if (playlistId == null) return;

    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return;

    Directory? materializedDir;
    try {
      var sourcePath = picked.path;
      if (sourcePath == null || sourcePath.isEmpty) {
        materializedDir = await Directory.systemTemp.createTemp(
          'spotiflac_playlist_cover_',
        );
        final pickedExtension = p.extension(picked.name);
        final materializedFile = File(
          p.join(
            materializedDir.path,
            'selected_cover${pickedExtension.isEmpty ? '.img' : pickedExtension}',
          ),
        );
        await materializedFile.writeAsBytes(
          await picked.readAsBytes(),
          flush: true,
        );
        sourcePath = materializedFile.path;
      }

      await ref
          .read(libraryCollectionsProvider.notifier)
          .setPlaylistCover(playlistId, sourcePath);
    } finally {
      try {
        if (materializedDir != null && await materializedDir.exists()) {
          await materializedDir.delete(recursive: true);
        }
      } catch (_) {
        // The cover has already been normalized into app storage.
      }
    }
  }

  Future<void> _removeCoverImage() async {
    final playlistId = widget.playlistId;
    if (playlistId == null) return;

    await ref
        .read(libraryCollectionsProvider.notifier)
        .removePlaylistCover(playlistId);
  }

  Widget _buildAppBar(
    BuildContext context,
    ColorScheme colorScheme,
    String title,
    List<CollectionTrackEntry> entries,
    UserPlaylistCollection? playlist,
  ) {
    final expandedHeight = calculateExpandedHeight(context);
    final customCoverPath = playlist?.coverImagePath;
    final isLovedMode = widget.mode == LibraryTracksFolderMode.loved;
    final isPlaylistMode = widget.mode == LibraryTracksFolderMode.playlist;
    final rawCoverUrl = isLovedMode ? null : _firstRawCoverUrl(entries);
    final localCoverUrl =
        rawCoverUrl == null && !isLovedMode && entries.isNotEmpty
        ? ref
              .watch(
                localLibraryFirstCoverProvider(_coverBatchRequest(entries)),
              )
              .maybeWhen(data: (cover) => cover, orElse: () => null)
        : null;
    final coverUrl = rawCoverUrl ?? localCoverUrl;
    final hasCustomCover =
        customCoverPath != null && customCoverPath.isNotEmpty;
    final hasCoverUrl = coverUrl != null;

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (MediaQuery.sizeOf(context).width * dpr).round().clamp(
      320,
      2048,
    );
    final coverFallback = Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(_modeIcon(), size: 80, color: colorScheme.onSurfaceVariant),
    );
    Widget squarePlaceholder() => Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(_modeIcon(), size: 48, color: colorScheme.onSurfaceVariant),
    );

    final Widget background = hasCustomCover
        ? Image.file(
            File(customCoverPath),
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) {
                return child;
              }
              return coverFallback;
            },
            errorBuilder: (_, _, _) => coverFallback,
          )
        : hasCoverUrl
        ? LocalOrNetworkCoverImage(
            url: coverUrl,
            fit: BoxFit.cover,
            localCacheWidth: cacheWidth,
            networkCacheWidth: cacheWidth,
            fadeInDuration: Duration.zero,
            urlTransform: (u) => highResCoverUrl(u) ?? u,
            placeholder: (_) => Container(color: colorScheme.surface),
          )
        : coverFallback;

    return AlbumDetailHeader(
      title: title,
      appBarTitle: isSelectionMode
          ? context.l10n.selectionSelected(selectedIds.length)
          : title,
      expandedHeight: expandedHeight,
      showTitleInAppBar: showTitleInAppBar,
      background: background,
      paletteSource: coverUrl,
      blurAndScrimBackground: hasCustomCover || hasCoverUrl,
      coverBuilder: (context, coverSize) {
        if (hasCustomCover) {
          return Image.file(
            File(customCoverPath),
            fit: BoxFit.cover,
            width: coverSize,
            height: coverSize,
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => squarePlaceholder(),
          );
        }
        if (hasCoverUrl) {
          return LocalOrNetworkCoverImage(
            url: coverUrl,
            fit: BoxFit.cover,
            width: coverSize,
            height: coverSize,
            localCacheWidth: cacheWidth,
            networkCacheWidth: cacheWidth,
            urlTransform: (u) => highResCoverUrl(u) ?? u,
            placeholder: (_) => squarePlaceholder(),
          );
        }
        return squarePlaceholder();
      },
      meta: entries.isNotEmpty
          ? HeaderMetaRow(
              items: [
                HeaderMetaItem(
                  context.l10n.tracksCount(entries.length),
                  icon: _modeIcon(),
                ),
              ],
            )
          : null,
      actions: entries.isNotEmpty
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(child: _buildPlayAllCenterButton(entries)),
                const SizedBox(width: 8),
                Flexible(child: _buildDownloadAllCenterButton(entries)),
              ],
            )
          : null,
      appBarActions: [
        if (!isSelectionMode && entries.isNotEmpty)
          IconButton(
            tooltip: context.l10n.collectionExportM3u,
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.ios_share, color: Colors.white, size: 20),
            ),
            onPressed: () => _exportAsM3u8(context, title, entries),
          ),
        if (isPlaylistMode && !isSelectionMode) ...[
          IconButton(
            tooltip: context.l10n.collectionRenamePlaylist,
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.edit_outlined,
                color: Colors.white,
                size: 20,
              ),
            ),
            onPressed: () {
              final id = widget.playlistId ?? playlist?.id;
              if (id == null || id.isEmpty) return;
              _showRenamePlaylistDialog(context, id, playlist?.name ?? title);
            },
          ),
          IconButton(
            tooltip: context.l10n.collectionPlaylistChangeCover,
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.camera_alt_outlined,
                color: Colors.white,
                size: 20,
              ),
            ),
            onPressed: () => _showCoverOptionsSheet(context, hasCustomCover),
          ),
        ],
      ],
      leading: IconButton(
        tooltip: isSelectionMode
            ? MaterialLocalizations.of(context).closeButtonTooltip
            : MaterialLocalizations.of(context).backButtonTooltip,
        icon: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isSelectionMode ? Icons.close : Icons.arrow_back,
            color: Colors.white,
          ),
        ),
        onPressed: isSelectionMode
            ? exitSelectionMode
            : () => Navigator.pop(context),
      ),
    );
  }

  Widget _buildPlayAllCenterButton(List<CollectionTrackEntry> entries) {
    final tracks = entries.map((e) => e.track).toList(growable: false);
    return HeaderFilledButton(
      icon: Icons.play_arrow_rounded,
      label: context.l10n.tooltipPlay,
      onPressed: tracks.isEmpty ? null : () => _playAll(tracks),
    );
  }

  Widget _buildDownloadAllCenterButton(List<CollectionTrackEntry> entries) {
    final tracks = entries.map((e) => e.track).toList(growable: false);
    return HeaderFilledButton(
      icon: Icons.download_rounded,
      label: context.l10n.downloadAllCount(tracks.length),
      onPressed: tracks.isEmpty ? null : () => _confirmDownloadAll(tracks),
    );
  }

  Future<void> _playAll(List<Track> tracks) async {
    if (tracks.isEmpty) return;

    try {
      await ref.read(musicPlayerControllerProvider).setShuffle(false);
      await ref.read(playbackProvider.notifier).playTrackList(tracks);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.snackbarCannotOpenFile('$e'))),
      );
    }
  }

  void _confirmDownloadAll(List<Track> tracks) {
    confirmDownloadAllDialog(
      context,
      tracks.length,
      () => _downloadAll(tracks),
    );
  }

  Future<void> _downloadAll(List<Track> tracks) async {
    final playlistName = widget.mode == LibraryTracksFolderMode.playlist
        ? playlist?.name ?? context.l10n.collectionPlaylist
        : null;
    await queueTracksSkippingDownloaded(
      context,
      ref,
      tracks,
      artistNameForPicker: switch (widget.mode) {
        LibraryTracksFolderMode.wishlist => context.l10n.collectionWishlist,
        LibraryTracksFolderMode.loved => context.l10n.collectionLoved,
        LibraryTracksFolderMode.playlist => context.l10n.collectionPlaylist,
      },
      playlistName: playlistName,
      resolveDefaultService: false,
    );
  }

  void _showCoverOptionsSheet(BuildContext context, bool hasCustomCover) {
    final colorScheme = Theme.of(context).colorScheme;

    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppSheetHandle(),
            const SizedBox(height: 16),
            AppSheetOption(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 4,
              ),
              leading: context.isMornye
                  ? Icon(
                      mornyeIconFor(Icons.image_outlined),
                      color: colorScheme.primary,
                    )
                  : Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.image_outlined,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
              title: Text(context.l10n.collectionPlaylistChangeCover),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickCoverImage();
              },
            ),
            if (hasCustomCover)
              AppSheetOption(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                leading: context.isMornye
                    ? Icon(
                        mornyeIconFor(Icons.delete_outline),
                        color: colorScheme.primary,
                      )
                    : Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.delete_outline,
                          color: colorScheme.onErrorContainer,
                        ),
                      ),
                title: Text(context.l10n.collectionPlaylistRemoveCover),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _removeCoverImage();
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _showRenamePlaylistDialog(
    BuildContext context,
    String playlistId,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final formKey = GlobalKey<FormState>();

    final nextName = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AppAlertDialog(
          title: Text(dialogContext.l10n.collectionRenamePlaylist),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: dialogContext.l10n.collectionPlaylistNameHint,
              ),
              validator: (value) {
                final trimmed = value?.trim() ?? '';
                if (trimmed.isEmpty) {
                  return dialogContext.l10n.collectionPlaylistNameRequired;
                }
                return null;
              },
              onFieldSubmitted: (_) {
                if (formKey.currentState?.validate() != true) return;
                Navigator.of(dialogContext).pop(controller.text.trim());
              },
            ),
          ),
          actions: [
            AppDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(dialogContext.l10n.dialogCancel),
            ),
            AppDialogAction(
              filled: true,
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.of(dialogContext).pop(controller.text.trim());
              },
              child: Text(dialogContext.l10n.dialogSave),
            ),
          ],
        );
      },
    );

    if (nextName == null || nextName.trim().isEmpty || !context.mounted) {
      return;
    }

    await ref
        .read(libraryCollectionsProvider.notifier)
        .renamePlaylist(playlistId, nextName.trim());

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.collectionPlaylistRenamed)),
    );
  }
}

class _CollectionTrackTile extends ConsumerWidget {
  final CollectionTrackEntry entry;
  final LibraryTracksFolderMode mode;
  final String? playlistId;
  final List<Track> folderTracks;
  final int trackIndex;
  final bool isInHistory;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _CollectionTrackTile({
    required this.entry,
    required this.mode,
    required this.playlistId,
    required this.folderTracks,
    required this.trackIndex,
    required this.isInHistory,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = entry.track;
    final colorScheme = Theme.of(context).colorScheme;
    final rawCoverUrl = _resolveRawCoverUrl(track);
    final localCoverUrl = rawCoverUrl == null
        ? ref
              .watch(
                localLibraryCoverProvider(
                  LocalLibraryCoverRequest(
                    isrc: track.isrc?.trim(),
                    trackName: track.name,
                    artistName: track.artistName,
                  ),
                ),
              )
              .maybeWhen(data: (cover) => cover, orElse: () => null)
        : null;
    final effectiveCoverUrl = rawCoverUrl ?? localCoverUrl;

    // Fine-grained provider watches – only this tile rebuilds when its own
    // history / local-library entry changes.
    final inMemoryHistoryItem = ref.watch(
      downloadHistoryProvider.select((state) {
        final byId = state.getBySpotifyId(track.id);
        if (byId != null) return byId;
        final isrc = track.isrc?.trim();
        if (isrc != null && isrc.isNotEmpty) {
          final byIsrc = state.getByIsrc(isrc);
          if (byIsrc != null) return byIsrc;
        }
        return state.findByTrackAndArtist(track.name, track.artistName);
      }),
    );
    final showLocalLibraryIndicator = ref.watch(
      settingsProvider.select(
        (s) => s.localLibraryEnabled && s.localLibraryShowDuplicates,
      ),
    );
    final isInLocalLibrary = showLocalLibraryIndicator
        ? ref.watch(
            localLibraryProvider.select((state) {
              final isrc = track.isrc?.trim();
              return state.existsInLibrary(
                isrc: isrc,
                trackName: track.name,
                artistName: track.artistName,
              );
            }),
          )
        : false;

    final heroTag = inMemoryHistoryItem != null
        ? 'cover_${inMemoryHistoryItem.id}'
        : null;

    return TrackCard(
      style: TrackCardStyle.flat,
      isSelectionMode: isSelectionMode,
      isSelected: isSelected,
      leading: HeroMode(
        enabled: heroTag != null,
        child: Builder(
          builder: (context) {
            final size = context.tokens.coverCompact;
            final cover = ClipRRect(
              borderRadius: context.tokens.borderRadiusThumb,
              child: effectiveCoverUrl != null && effectiveCoverUrl.isNotEmpty
                  ? _buildTrackCover(context, effectiveCoverUrl, size)
                  : TrackCoverPlaceholder(size: size),
            );
            return heroTag != null ? Hero(tag: heroTag, child: cover) : cover;
          },
        ),
      ),
      title: track.name,
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              track.artistName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
          if (isInLocalLibrary || isInHistory) ...[
            const SizedBox(width: 6),
            const InLibraryBadge(),
          ],
        ],
      ),
      trailing: isInHistory || isInLocalLibrary
          ? IconButton(
              tooltip: context.l10n.tooltipPlay,
              onPressed: () => _playFromHere(context, ref),
              icon: Icon(Icons.play_arrow, color: colorScheme.primary),
              style: IconButton.styleFrom(
                minimumSize: Size.square(context.tokens.minTouchTarget),
                backgroundColor: colorScheme.primaryContainer.withValues(
                  alpha: 0.3,
                ),
              ),
            )
          : null,
      onTap: isSelectionMode
          ? onTap
          : () {
              if (mode == LibraryTracksFolderMode.wishlist) {
                _downloadTrack(context, ref);
                return;
              }

              _navigateToMetadata(context, ref);
            },
      onLongPress: isSelectionMode ? onTap : onLongPress,
    );
  }

  Future<void> _playFromHere(BuildContext context, WidgetRef ref) async {
    try {
      await ref
          .read(playbackProvider.notifier)
          .playTrackList(folderTracks, startIndex: trackIndex);
    } catch (error) {
      if (!context.mounted) return;
      showCannotOpenFileSnackBar(context, error);
    }
  }

  Widget _buildTrackCover(BuildContext context, String coverUrl, double size) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget placeholder() => Container(
      width: size,
      height: size,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
    );

    return LocalOrNetworkCoverImage(
      url: coverUrl,
      width: size,
      height: size,
      networkCacheWidth: (size * 2).toInt(),
      fadeInDuration: const Duration(milliseconds: 180),
      fadeOutDuration: const Duration(milliseconds: 90),
      placeholder: (_) => placeholder(),
    );
  }

  void _downloadTrack(BuildContext context, WidgetRef ref) {
    downloadSingleTrack(context, ref, entry.track);
  }

  Future<void> _navigateToMetadata(BuildContext context, WidgetRef ref) async {
    final track = entry.track;
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);

    var historyItem = await historyNotifier.getBySpotifyIdAsync(track.id);
    if (!context.mounted) return;

    if (historyItem == null && track.isrc != null && track.isrc!.isNotEmpty) {
      historyItem = await historyNotifier.getByIsrcAsync(track.isrc!);
      if (!context.mounted) return;
    }

    historyItem ??= await historyNotifier.findByTrackAndArtistAsync(
      track.name,
      track.artistName,
    );
    if (!context.mounted) return;

    if (historyItem != null) {
      final embeddedCoverPath =
          await DownloadedEmbeddedCoverResolver.resolveOrExtract(
            historyItem.filePath,
          );
      if (!context.mounted) return;
      await precacheMetadataBackdrop(
        context,
        embeddedCoverPath ?? historyItem.coverUrl,
      );
      if (!context.mounted) return;
      await Navigator.of(context).push(
        slidePageRoute<void>(page: TrackMetadataScreen(item: historyItem)),
      );
      return;
    }

    final localItem = await ref
        .read(localLibraryProvider.notifier)
        .findExistingAsync(
          isrc: track.isrc,
          trackName: track.name,
          artistName: track.artistName,
        );
    if (!context.mounted) return;

    if (localItem != null) {
      await precacheMetadataBackdrop(context, localItem.coverPath);
      if (!context.mounted) return;
      await Navigator.of(context).push(
        slidePageRoute<void>(page: TrackMetadataScreen(localItem: localItem)),
      );
      return;
    }

    _downloadTrack(context, ref);
  }
}

class _EmptyFolderState extends StatelessWidget {
  final String title;
  final String subtitle;

  const _EmptyFolderState({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open,
              size: 60,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum LibraryTracksFolderMode { wishlist, loved, playlist }
