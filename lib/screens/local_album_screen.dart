import 'dart:io';
import 'dart:math';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:mosix/services/deleted_library_files.dart';
import 'package:flutter/material.dart';
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/services/local_track_batch_actions.dart';
import 'package:mosix/theme/cover_palette.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/utils/adaptive_layout.dart';
import 'package:mosix/utils/audio_quality_badge_policy.dart';
import 'package:mosix/utils/confirm_and_delete_tracks.dart';
import 'package:mosix/utils/file_access.dart';
import 'package:mosix/utils/image_cache_utils.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/services/batch_track_actions.dart';
import 'package:mosix/models/album_track_order.dart';
import 'package:mosix/models/unified_library_item.dart';
import 'package:mosix/services/local_track_redownload_service.dart';
import 'package:mosix/providers/local_library_provider.dart';
import 'package:mosix/providers/playback_provider.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/player_motion_artwork_provider.dart';
import 'package:mosix/screens/collapsing_header_scroll_mixin.dart';
import 'package:mosix/screens/selection_mode_mixin.dart';
import 'package:mosix/screens/track_metadata_screen.dart';
import 'package:mosix/widgets/collection_scaffold.dart';
import 'package:mosix/widgets/album_track_tile.dart';
import 'package:mosix/widgets/animation_utils.dart';
import 'package:mosix/widgets/app_snack_bar.dart';
import 'package:mosix/widgets/destructive_selection_button.dart';
import 'package:mosix/widgets/selection_action_button.dart';
import 'package:mosix/widgets/selection_bottom_bar.dart';
import 'package:mosix/widgets/library_selection_playback_actions.dart';
import 'package:mosix/widgets/disc_separator_chip.dart';
import 'package:mosix/widgets/album_detail_header.dart';
import 'package:mosix/widgets/mornye_artist_header.dart';
import 'package:mosix/widgets/motion_header_banner.dart';

class LocalAlbumScreen extends ConsumerStatefulWidget {
  final String albumName;
  final String artistName;
  final String? coverPath;
  final List<LocalLibraryItem> tracks;
  final Future<List<LocalLibraryItem>> Function()? loadTracks;

  const LocalAlbumScreen({
    super.key,
    required this.albumName,
    required this.artistName,
    this.coverPath,
    this.tracks = const [],
    this.loadTracks,
  });

  @override
  ConsumerState<LocalAlbumScreen> createState() => _LocalAlbumScreenState();
}

class _LocalAlbumScreenState extends ConsumerState<LocalAlbumScreen>
    with
        SelectionModeMixin<LocalAlbumScreen>,
        CollapsingHeaderScrollMixin<LocalAlbumScreen> {
  late AlbumTrackOrder<LocalLibraryItem> _trackOrder;
  List<LocalLibraryItem> get _sortedTracksCache => _trackOrder.tracks;
  Map<int, List<LocalLibraryItem>> get _discGroupsCache =>
      _trackOrder.discGroups;
  List<LocalLibraryItem>? _loadedTracks;
  bool _loadingTracks = false;
  Object? _loadError;
  int _loadGeneration = 0;

  void _showCueVirtualTrackSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(cueVirtualTrackRequiresSplitMessage)),
    );
  }

  List<int> get _sortedDiscNumbersCache => _trackOrder.discNumbers;
  bool get _hasMultipleDiscsCache => _trackOrder.discGroups.length > 1;
  String? _commonQualityCache;
  String? _commonQualityModeCache;

  @override
  void initState() {
    super.initState();
    _rebuildTrackCaches();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    final loader = widget.loadTracks;
    if (loader == null) return;
    final generation = ++_loadGeneration;
    _loadingTracks = true;
    _loadError = null;
    try {
      final tracks = await loader();
      if (!mounted || generation != _loadGeneration) return;
      _loadedTracks = tracks;
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      _loadError = error;
    }
    _loadingTracks = false;
    setState(_rebuildTrackCaches);
  }

  @override
  void didUpdateWidget(covariant LocalAlbumScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tracks, widget.tracks) ||
        oldWidget.tracks.length != widget.tracks.length ||
        oldWidget.loadTracks != widget.loadTracks) {
      _loadGeneration++;
      _loadedTracks = null;
      _loadingTracks = false;
      _loadError = null;
      _rebuildTrackCaches();
      _loadTracks();
    }
  }

  void _rebuildTrackCaches() {
    _trackOrder = AlbumTrackOrder(
      _loadedTracks ?? widget.tracks,
      discNumber: (track) => track.discNumber,
      trackNumber: (track) => track.trackNumber,
      trackName: (track) => track.trackName,
    );
    _commonQualityCache = null;
    _commonQualityModeCache = null;
  }

  Future<void> _deleteSelected(List<LocalLibraryItem> currentTracks) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final libraryNotifier = ref.read(localLibraryProvider.notifier);
    final tracksById = {for (final track in currentTracks) track.id: track};

    final deletedCount = await confirmAndDeleteTracks(
      context: context,
      ids: selectedIds.toList(),
      deleteItem: (id) async {
        final item = tracksById[id];
        if (item == null) return false;
        if (!isCueVirtualPath(item.filePath)) {
          final deleted = await deleteFile(item.filePath);
          if (!deleted) return false;
        }
        return true;
      },
      persistDeletedItems: (ids) async {
        final items = ids.map((id) => tracksById[id]!);
        await removeDeletedLibraryFileEntries(
          container,
          items
              .where((item) => !isCueVirtualPath(item.filePath))
              .map((item) => item.filePath),
        );
        await libraryNotifier.removeItems(
          items
              .where((item) => isCueVirtualPath(item.filePath))
              .map((item) => item.id),
        );
      },
      onExitSelectionMode: exitSelectionMode,
    );

    if (deletedCount == currentTracks.length && mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _openFile(LocalLibraryItem track) async {
    if (isCueVirtualPath(track.filePath)) {
      _showCueVirtualTrackSnackBar();
      return;
    }
    try {
      await ref
          .read(playbackProvider.notifier)
          .playLocalLibraryQueue(_sortedTracksCache, startItem: track);
    } catch (e) {
      if (mounted) showCannotOpenFileSnackBar(context, e);
    }
  }

  Future<void> _openMetadata(LocalLibraryItem track) async {
    final tracks = _sortedTracksCache;
    await Navigator.of(context).push(
      slidePageRoute<void>(
        page: TrackMetadataScreen(
          localItem: track,
          localNavigationItems: tracks,
          navigationIndex: tracks.indexWhere((item) => item.id == track.id),
        ),
      ),
    );
  }

  bool _isCurrentTrack(MediaItem? item, LocalLibraryItem track) {
    if (item == null) return false;
    // Playlist playback can use the file path rather than the Library row ID.
    final source = item.extras?['source'];
    return source is String && source.isNotEmpty
        ? source == track.filePath
        : item.id == track.id || item.id == track.filePath;
  }

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return MornyeArtistSurface(
        imageSource: widget.coverPath,
        neutralActions: true,
        child: Builder(builder: _buildPage),
      );
    }
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final qualityLabelMode = ref.watch(
      settingsProvider.select((s) => s.libraryQualityLabelMode),
    );
    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;
    final tracks = _sortedTracksCache;

    if (tracks.isEmpty && !_loadingTracks && _loadError == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.albumName)),
        body: Center(child: Text(context.l10n.noTracksFoundForAlbum)),
      );
    }

    pruneSelection(tracks.map((t) => t.id).toSet());

    return CollectionScaffold(
      scrollController: scrollController,
      isSelectionMode: isSelectionMode,
      onExitSelectionMode: exitSelectionMode,
      appBar: _buildAppBar(context, colorScheme, qualityLabelMode),
      slivers: [
        if (_loadError != null)
          SliverToBoxAdapter(
            child: Center(
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _loadTracks();
                }),
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.dialogRetry),
              ),
            ),
          )
        else if (_loadingTracks)
          const SliverToBoxAdapter(
            child: RepaintBoundary(child: AlbumTrackListSkeleton(itemCount: 8)),
          )
        else
          _buildTrackList(context, colorScheme, tracks),
      ],
      selectionBar: _buildSelectionBottomBar(
        context,
        colorScheme,
        tracks,
        bottomPadding,
      ),
    );
  }

  Widget _buildAppBar(
    BuildContext context,
    ColorScheme colorScheme,
    String qualityLabelMode,
  ) {
    final expandedHeight = calculateExpandedHeight(context);
    final motion = context.isMornye && !MediaQuery.disableAnimationsOf(context)
        ? ref
              .watch(
                playerMotionArtworkProvider((
                  album: widget.albumName,
                  artist:
                      _sortedTracksCache.firstOrNull?.artistName ??
                      widget.artistName,
                )),
              )
              .value
        : null;

    final cacheWidth = coverCacheWidthForViewport(context);
    final Widget background = widget.coverPath != null
        ? Image.file(
            File(widget.coverPath!),
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            errorBuilder: (_, _, _) => Container(color: colorScheme.surface),
          )
        : Container(
            color: colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.album,
              size: 80,
              color: colorScheme.onSurfaceVariant,
            ),
          );

    return AlbumDetailHeader(
      title: widget.albumName,
      immersive: context.isMornye,
      squareArtwork: motion == null,
      expandedHeight: expandedHeight,
      showTitleInAppBar: showTitleInAppBar,
      background: motion == null
          ? background
          : MotionHeaderBanner(videoUrl: motion.source, fallback: background),
      paletteSource: widget.coverPath,
      blurAndScrimBackground: widget.coverPath != null,
      coverBuilder: (context, coverSize) => widget.coverPath != null
          ? Image.file(
              File(widget.coverPath!),
              fit: BoxFit.cover,
              width: coverSize,
              height: coverSize,
              cacheWidth: cacheWidth,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Container(
                color: colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.album,
                  size: 48,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : Container(
              color: colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.album,
                size: 48,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
      subtitle: Text(
        widget.artistName,
        style: TextStyle(
          color: context.isMornye
              ? colorScheme.primary
              : HeaderPalette.of(context).onSurfaceVariant,
          fontSize: context.tokens.headerSubtitleSize,
          fontWeight: context.isMornye ? FontWeight.w400 : FontWeight.w600,
        ),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      meta: _buildLocalHeaderMeta(context, qualityLabelMode),
      actions: Consumer(
        builder: (context, ref, _) {
          final isCurrent = ref.watch(
            currentMediaItemProvider.select(
              (state) => _sortedTracksCache.any(
                (track) => _isCurrentTrack(state.value, track),
              ),
            ),
          );
          final isPlaying = isCurrent && ref.watch(playbackPlayingProvider);
          return AlbumPlayActions(
            isPlaying: isPlaying,
            playLabel: isPlaying
                ? context.l10n.actionPause
                : context.l10n.tooltipPlay,
            shuffleTooltip: context.l10n.actionShuffle,
            onPlay: isCurrent
                ? () => ref
                      .read(musicPlayerControllerProvider)
                      .togglePlayPause(isPlaying)
                : _playAll,
            onShuffle: _shuffleAll,
          );
        },
      ),
    );
  }

  Widget _buildLocalHeaderMeta(BuildContext context, String qualityLabelMode) {
    final tracks = _sortedTracksCache;
    final totalSeconds = tracks.fold<int>(
      0,
      (sum, t) => sum + ((t.duration ?? 0) > 0 ? t.duration! : 0),
    );
    final totalMinutes = (totalSeconds / 60).round();
    final quality = _getCommonQuality(qualityLabelMode);

    return HeaderMetaRow(
      items: [
        HeaderMetaItem(context.l10n.queueTrackCount(tracks.length)),
        if (totalMinutes > 0) HeaderMetaItem('$totalMinutes min'),
        if (quality != null && quality.isNotEmpty)
          HeaderMetaItem(quality, icon: Icons.graphic_eq),
      ],
    );
  }

  Future<void> _playAll() async {
    final tracks = _sortedTracksCache;
    if (tracks.isEmpty) return;
    await ref.read(musicPlayerControllerProvider).setShuffle(false);
    await _openFile(tracks.first);
  }

  Future<void> _shuffleAll() async {
    final tracks = _sortedTracksCache
        .where((t) => !isCueVirtualPath(t.filePath))
        .toList();
    if (tracks.isEmpty) return;
    await ref.read(musicPlayerControllerProvider).setShuffle(true);
    await _openFile(tracks[Random().nextInt(tracks.length)]);
  }

  String? _getCommonQuality(String mode) {
    if (_commonQualityModeCache == mode) return _commonQualityCache;
    _commonQualityModeCache = mode;
    _commonQualityCache = _computeCommonQuality(_sortedTracksCache, mode);
    return _commonQualityCache;
  }

  String? _computeCommonQuality(List<LocalLibraryItem> tracks, String mode) {
    if (tracks.isEmpty) return null;
    String? label(LocalLibraryItem track) => buildLibraryAudioQualityLabel(
      mode: mode,
      format: track.format,
      filePath: track.filePath,
      bitrateKbps: track.bitrate,
      bitDepth: track.bitDepth,
      sampleRate: track.sampleRate,
    );

    final firstQuality = label(tracks.first);
    if (firstQuality == null) return null;
    for (final track in tracks) {
      if (label(track) != firstQuality) return null;
    }
    return firstQuality;
  }

  Widget _buildTrackList(
    BuildContext context,
    ColorScheme colorScheme,
    List<LocalLibraryItem> tracks,
  ) {
    final discGroups = _discGroupsCache;
    final hasMultipleDiscs = _hasMultipleDiscsCache;

    final slivers = <Widget>[];

    for (final discNumber in _sortedDiscNumbersCache) {
      final discTracks = discGroups[discNumber]!;

      if (hasMultipleDiscs) {
        slivers.add(
          SliverToBoxAdapter(child: DiscSeparatorChip(discNumber: discNumber)),
        );
      }

      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final track = discTracks[index];
            return KeyedSubtree(
              key: ValueKey(track.id),
              child: StaggeredListItem(
                index: index,
                animate: widget.loadTracks == null,
                child: _buildTrackItem(context, colorScheme, track),
              ),
            );
          }, childCount: discTracks.length),
        ),
      );
    }

    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverMainAxisGroup(slivers: slivers),
    );
  }

  Widget _buildTrackItem(
    BuildContext context,
    ColorScheme colorScheme,
    LocalLibraryItem track,
  ) {
    return Consumer(
      builder: (context, ref, _) {
        final isCurrent = ref.watch(
          currentMediaItemProvider.select(
            (state) => _isCurrentTrack(state.value, track),
          ),
        );
        final isPlaying = isCurrent && ref.watch(playbackPlayingProvider);
        return AlbumTrackTile(
          isPlaying: isPlaying,
          trackNumber: track.trackNumber,
          trackName: track.trackName,
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
              if (track.format != null) ...[
                Text(
                  ' • ',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                Text(
                  track.format!.toUpperCase(),
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
          isSelectionMode: isSelectionMode,
          isSelected: selectedIds.contains(track.id),
          colorScheme: colorScheme,
          onToggleSelection: () => toggleSelection(track.id),
          onOpen: () => _openMetadata(track),
          onEnterSelectionMode: () => enterSelectionMode(track.id),
          onPlay: isCurrent
              ? () => ref
                    .read(musicPlayerControllerProvider)
                    .togglePlayPause(isPlaying)
              : () => _openFile(track),
        );
      },
    );
  }

  List<LocalLibraryItem> _selectedFlacEligibleItems(
    List<LocalLibraryItem> allTracks,
  ) {
    final tracksById = {for (final t in allTracks) t.id: t};
    return selectedIds
        .map((id) => tracksById[id])
        .whereType<LocalLibraryItem>()
        .where(LocalTrackRedownloadService.isFlacUpgradeEligible)
        .toList(growable: false);
  }

  Future<void> _queueSelectedAsFlac(List<LocalLibraryItem> allTracks) =>
      queueLocalTracksAsFlac(
        context,
        ref,
        _selectedFlacEligibleItems(allTracks),
        isActive: () => mounted,
        onComplete: exitSelectionMode,
      );

  Future<void> _reEnrichSelected(List<LocalLibraryItem> allTracks) async {
    final tracksById = {for (final track in allTracks) track.id: track};
    final selected = [for (final id in selectedIds) ?tracksById[id]];
    await reEnrichLocalTracks(
      context,
      ref,
      selected,
      isActive: () => mounted,
      onSelectionHide: () async {
        setState(() => isSelectionMode = false);
        // Allow the selection bar's 250 ms slide-out to finish.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      },
      onSelectionRestore: () => setState(() => isSelectionMode = true),
      onComplete: exitSelectionMode,
    );
  }

  List<UnifiedLibraryItem> _selectedUnifiedItems(
    List<LocalLibraryItem> tracks,
  ) {
    final tracksById = {for (final t in tracks) t.id: t};
    return [
      for (final t in selectedIds.map((id) => tracksById[id]))
        if (t != null) UnifiedLibraryItem.fromLocalLibrary(t),
    ];
  }

  Widget _buildSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<LocalLibraryItem> tracks,
    double bottomPadding,
  ) {
    final selectedCount = selectedIds.length;
    final flacEligibleCount = _selectedFlacEligibleItems(tracks).length;
    final allSelected = selectedCount == tracks.length && tracks.isNotEmpty;

    return SelectionBottomBar(
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: exitSelectionMode,
      onToggleSelectAll: () {
        if (allSelected) {
          exitSelectionMode();
        } else {
          selectAll(tracks.map((e) => e.id));
        }
      },
      bottomPadding: bottomPadding,
      children: [
        LibrarySelectionPlaybackActions(
          items: _selectedUnifiedItems(tracks),
          onClose: exitSelectionMode,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(context.l10n.trackEditMetadata),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 8.0;
            final columns = (constraints.maxWidth / 320).floor().clamp(2, 4);
            final itemWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;
            final actions = <Widget>[];

            if (flacEligibleCount > 0) {
              actions.add(
                SelectionActionButton(
                  icon: Icons.download_for_offline_outlined,
                  label: '${context.l10n.queueFlacAction} ($flacEligibleCount)',
                  onPressed: () => _queueSelectedAsFlac(tracks),
                  colorScheme: colorScheme,
                ),
              );
            }

            actions.add(
              SelectionActionButton(
                icon: Icons.auto_fix_high_outlined,
                label: '${context.l10n.trackReEnrich} ($selectedCount)',
                onPressed: selectedCount > 0
                    ? () => _reEnrichSelected(tracks)
                    : null,
                colorScheme: colorScheme,
              ),
            );

            actions.add(
              SelectionActionButton(
                icon: Icons.swap_horiz,
                label: context.l10n.selectionConvertCount(selectedCount),
                onPressed: selectedCount > 0
                    ? () => showBatchConvertSheet(
                        this.context,
                        ref,
                        _selectedUnifiedItems(tracks),
                        onExitSelectionMode: exitSelectionMode,
                      )
                    : null,
                colorScheme: colorScheme,
              ),
            );

            for (final remove in [false, true]) {
              actions.add(
                SelectionActionButton(
                  icon: remove ? Icons.remove_circle_outline : Icons.graphic_eq,
                  label: remove
                      ? context.l10n.selectionRemoveReplayGainCount(
                          selectedCount,
                        )
                      : context.l10n.selectionReplayGainCount(selectedCount),
                  onPressed: selectedCount > 0
                      ? () => runBatchReplayGain(
                          this.context,
                          _selectedUnifiedItems(tracks),
                          onExitSelectionMode: exitSelectionMode,
                          remove: remove,
                        )
                      : null,
                  colorScheme: colorScheme,
                ),
              );
            }

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final action in actions)
                  SizedBox(width: itemWidth, child: action),
              ],
            );
          },
        ),

        const SizedBox(height: 8),
        DestructiveSelectionButton(
          count: selectedCount,
          colorScheme: colorScheme,
          onPressed: () => _deleteSelected(tracks),
        ),
      ],
    );
  }
}
