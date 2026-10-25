import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/unified_library_item.dart';
import 'package:mosix/providers/library_search_provider.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/playback_provider.dart';
import 'package:mosix/screens/downloaded_album_screen.dart';
import 'package:mosix/screens/library_tracks_folder_screen.dart';
import 'package:mosix/screens/local_album_screen.dart';
import 'package:mosix/screens/track_metadata_screen.dart';
import 'package:mosix/services/batch_track_actions.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/services/library_search.dart';
import 'package:mosix/services/local_track_batch_actions.dart';
import 'package:mosix/services/local_track_redownload_service.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/widgets/app_choice_chip.dart';
import 'package:mosix/widgets/cached_cover_image.dart';
import 'package:mosix/widgets/library_track_selection_bar.dart';
import 'package:mosix/widgets/library_selection_playback_actions.dart';
import 'package:mosix/widgets/selection_bottom_bar.dart';
import 'package:mosix/widgets/track_card.dart';

/// Slivers shared by Material's Library and Mornye's Library/Songs screens.
/// Only the current query's provider families are watched; late results from
/// an earlier query cannot replace what the user is currently searching for.
class LibrarySearchResults extends ConsumerStatefulWidget {
  const LibrarySearchResults({
    super.key,
    required this.query,
    required this.onOpenArtist,
  });

  final String query;
  final ValueChanged<String> onOpenArtist;

  @override
  ConsumerState<LibrarySearchResults> createState() =>
      _LibrarySearchResultsState();
}

class _LibrarySearchResultsState extends ConsumerState<LibrarySearchResults> {
  LibrarySearchKind? _kind;
  int _pages = 1;

  // Long-pressed songs, keyed by UnifiedLibraryItem.id in selection order.
  // Only resolved records are kept, so every bar action sees real files.
  final Map<String, UnifiedLibraryItem> _selected = {};
  final SelectionOverlayController _selectionOverlay =
      SelectionOverlayController();
  // Hidden while a sheet or dialog opened from the bar is on screen.
  bool _suppressSelectionBar = false;
  List<LibrarySearchHit> _visibleSongs = const [];

  bool get _selecting => _selected.isNotEmpty;

  @override
  void didUpdateWidget(covariant LibrarySearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      _pages = 1;
      // A selection belongs to the results it was made in.
      _selected.clear();
      _suppressSelectionBar = false;
      _selectionOverlay.hide();
    }
  }

  @override
  void dispose() {
    _selectionOverlay.dispose();
    super.dispose();
  }

  static String _itemId(LibrarySearchHit hit) =>
      hit.source == 'local' ? 'local_${hit.id}' : 'dl_${hit.id}';

  Future<UnifiedLibraryItem?> _resolve(LibrarySearchHit hit) => ref.read(
    librarySearchTrackProvider((source: hit.source, id: hit.id)).future,
  );

  Future<void> _toggleSelection(LibrarySearchHit hit) async {
    final id = _itemId(hit);
    if (_selected.containsKey(id)) {
      setState(() => _selected.remove(id));
      return;
    }
    final item = await _resolve(hit);
    if (!mounted || item == null) return;
    if (_selected.isEmpty) {
      FocusScope.of(context).unfocus();
      HapticFeedback.mediumImpact();
    }
    setState(() => _selected[item.id] = item);
  }

  Future<void> _selectAllVisible() async {
    final items = await Future.wait(
      _visibleSongs
          .where((hit) => !_selected.containsKey(_itemId(hit)))
          .map(_resolve),
    );
    if (!mounted) return;
    setState(() {
      for (final item in items.whereType<UnifiedLibraryItem>()) {
        _selected[item.id] = item;
      }
    });
  }

  void _exitSelection() {
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _suppressSelectionBar = false;
    });
    _selectionOverlay.hide();
  }

  void _finishSelectionAction() {
    _exitSelection();
    ref.invalidate(librarySearchProvider);
  }

  void _hideSelectionBar() {
    _suppressSelectionBar = true;
    _selectionOverlay.hide();
  }

  Future<void> _restoreSelectionBar({Duration delay = Duration.zero}) async {
    // Wait out the sheet/dialog exit so the bar does not cover it.
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    _suppressSelectionBar = false;
    if (mounted) setState(() {});
  }

  void _syncSelectionBar() {
    if (!mounted) return;
    if (!_selecting || _suppressSelectionBar) {
      _selectionOverlay.hide();
      return;
    }
    _selectionOverlay.show(context, _buildSelectionBar);
  }

  Widget _buildSelectionBar(BuildContext _) {
    final items = _selected.values.toList(growable: false);
    final visibleIds = _visibleSongs.map(_itemId).toSet();
    final allSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selected.containsKey);
    final flacEligible = items.every((item) => item.localItem != null)
        ? items
              .map((item) => item.localItem!)
              .where(LocalTrackRedownloadService.isFlacUpgradeEligible)
              .toList(growable: false)
        : const <LocalLibraryItem>[];
    return LibraryTrackSelectionBar(
      playbackActions: LibrarySelectionPlaybackActions(
        items: items,
        onClose: _exitSelection,
      ),
      selectedCount: items.length,
      allSelected: allSelected,
      onClose: _exitSelection,
      onToggleSelectAll: allSelected ? _exitSelection : _selectAllVisible,
      bottomPadding: MediaQuery.paddingOf(context).bottom,
      flacEligibleCount: flacEligible.length,
      onQueueFlac: () => queueLocalTracksAsFlac(
        context,
        ref,
        flacEligible,
        isActive: () => mounted,
        onComplete: _exitSelection,
      ),
      onReEnrich: () => reEnrichLibraryTracks(
        context,
        ref,
        items,
        isActive: () => mounted,
        onSelectionHide: () async => _hideSelectionBar(),
        onSelectionRestore: _restoreSelectionBar,
        onComplete: _finishSelectionAction,
      ),
      onConvert: () => showBatchConvertSheet(
        context,
        ref,
        items,
        onExitSelectionMode: _finishSelectionAction,
        onSheetOpen: _hideSelectionBar,
        onSheetClosed: (_) =>
            _restoreSelectionBar(delay: const Duration(milliseconds: 260)),
      ),
      onReplayGain: ({required remove}) => runBatchReplayGain(
        context,
        items,
        remove: remove,
        onExitSelectionMode: _exitSelection,
        onConfirmOpen: _hideSelectionBar,
        onConfirmClosed: (confirmed) => _restoreSelectionBar(
          delay: confirmed ? Duration.zero : const Duration(milliseconds: 220),
        ),
      ),
      onDelete: () => deleteLibraryTracks(
        context,
        ref,
        items,
        isActive: () => mounted,
        onComplete: _finishSelectionAction,
      ),
    );
  }

  String _label(LibrarySearchKind kind) => switch (kind) {
    LibrarySearchKind.songs => context.l10n.searchSongs,
    LibrarySearchKind.albums => context.l10n.searchAlbums,
    LibrarySearchKind.artists => context.l10n.searchArtists,
    LibrarySearchKind.playlists => context.l10n.searchPlaylists,
  };

  void _select(LibrarySearchKind? kind) => setState(() {
    _kind = kind;
    _pages = 1;
  });

  Future<void> _open(LibrarySearchHit hit, {bool play = false}) async {
    FocusScope.of(context).unfocus();
    try {
      switch (hit.kind) {
        case LibrarySearchKind.songs:
          final item = await ref.read(
            librarySearchTrackProvider((source: hit.source, id: hit.id)).future,
          );
          if (!mounted || item == null) return;
          if (!play) {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TrackMetadataScreen(
                  item: item.historyItem,
                  localItem: item.localItem,
                ),
              ),
            );
            return;
          }
          final media = item.localItem != null
              ? playableFromLocal(item.localItem!)
              : playableFromHistory(item.historyItem!);
          await ref
              .read(playbackProvider.notifier)
              .playMediaQueue(
                [media],
                startIndex: 0,
                externalPath: media.source,
              );
        case LibrarySearchKind.artists:
          widget.onOpenArtist(hit.title);
        case LibrarySearchKind.playlists:
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => LibraryTracksFolderScreen(
                mode: LibraryTracksFolderMode.playlist,
                playlistId: hit.id,
              ),
            ),
          );
        case LibrarySearchKind.albums:
          if (hit.source == 'local') {
            final rows = await LibraryDatabase.instance
                .getQueueLocalAlbumTracksByKey(hit.id);
            if (!mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LocalAlbumScreen(
                  albumName: hit.title,
                  artistName: hit.artist,
                  coverPath: hit.cover,
                  tracks: rows.map(LocalLibraryItem.fromJson).toList(),
                ),
              ),
            );
          } else {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DownloadedAlbumScreen(
                  albumName: hit.title,
                  artistName: hit.artist,
                  coverUrl: hit.cover,
                ),
              ),
            );
          }
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.snackbarCannotOpenFile('$error'))),
      );
    }
  }

  Widget _row(LibrarySearchHit hit) {
    final icon = switch (hit.kind) {
      LibrarySearchKind.songs => Icons.music_note_outlined,
      LibrarySearchKind.albums => Icons.album_outlined,
      LibrarySearchKind.artists => Icons.person_outline,
      LibrarySearchKind.playlists => Icons.queue_music,
    };
    final subtitle = hit.kind == LibrarySearchKind.songs
        ? hit.artist
        : [
            if (hit.kind == LibrarySearchKind.albums) hit.artist,
            context.l10n.queueTrackCount(hit.trackCount),
          ].join(' · ');
    Widget fallback(BuildContext context) => ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(icon)),
    );
    final song = hit.kind == LibrarySearchKind.songs;
    return TrackCard(
      key: ValueKey('${hit.kind.name}:${hit.source}:${hit.id}'),
      style: hit.kind == LibrarySearchKind.songs && !context.isMornye
          ? TrackCardStyle.filled
          : TrackCardStyle.flat,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(
          hit.kind == LibrarySearchKind.artists ? 28 : 8,
        ),
        child: SizedBox.square(
          dimension: 52,
          child: hit.cover?.isNotEmpty == true
              ? LocalOrNetworkCoverImage(url: hit.cover!, placeholder: fallback)
              : fallback(context),
        ),
      ),
      title: hit.title,
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: song
          ? IconButton(
              tooltip: context.l10n.tooltipPlay,
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () => _open(hit, play: true),
            )
          : const Icon(Icons.chevron_right),
      // Long-press selects songs for the Library batch actions; while
      // selecting, song taps toggle and other results stay inert.
      isSelectionMode: song && _selecting,
      isSelected: song && _selected.containsKey(_itemId(hit)),
      onTap: !_selecting
          ? () => _open(hit)
          : song
          ? () => _toggleSelection(hit)
          : null,
      onLongPress: song ? () => _toggleSelection(hit) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            spacing: 8,
            children: [
              for (final kind in [null, ...LibrarySearchKind.values])
                AppChoiceChip(
                  label: Text(
                    kind == null ? context.l10n.historyFilterAll : _label(kind),
                  ),
                  selected: _kind == kind,
                  singleChoice: true,
                  onSelected: (_) => _select(kind),
                ),
            ],
          ),
        ),
      ),
    ];
    var hasResults = false;
    var loading = false;
    var failed = false;
    final visibleSongs = <LibrarySearchHit>[];
    for (final kind in _kind == null ? LibrarySearchKind.values : [_kind!]) {
      for (var page = 0; page < (_kind == null ? 1 : _pages); page++) {
        final pageSize = _kind == null ? 5 : 40;
        final request = (
          query: widget.query,
          kind: kind,
          limit: pageSize + 1,
          offset: page * pageSize,
        );
        final result = ref.watch(librarySearchProvider(request));
        loading |= result.isLoading;
        failed |= result.hasError;
        final hits = result.value ?? const <LibrarySearchHit>[];
        if (kind == LibrarySearchKind.songs) {
          visibleSongs.addAll(hits.take(pageSize));
        }
        if (hits.isNotEmpty) {
          hasResults = true;
          if (page == 0) {
            slivers.add(
              SliverToBoxAdapter(
                child: ListTile(
                  title: Text(
                    _label(kind),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  trailing: _kind == null
                      ? const Icon(Icons.chevron_right)
                      : null,
                  onTap: _kind == null ? () => _select(kind) : null,
                ),
              ),
            );
          }
          slivers.add(
            SliverList.builder(
              itemCount: hits.length.clamp(0, pageSize),
              itemBuilder: (context, index) => _row(hits[index]),
            ),
          );
          if (_kind != null && page == _pages - 1 && hits.length > pageSize) {
            slivers.add(
              SliverToBoxAdapter(
                child: Center(
                  child: IconButton(
                    tooltip: _label(kind),
                    icon: const Icon(Icons.expand_more),
                    onPressed: () => setState(() => _pages++),
                  ),
                ),
              ),
            );
          }
        }
        if (result.hasError) {
          slivers.add(
            SliverToBoxAdapter(
              child: Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: Text('${_label(kind)} · ${context.l10n.dialogRetry}'),
                  onPressed: () =>
                      ref.invalidate(librarySearchProvider(request)),
                ),
              ),
            ),
          );
        }
      }
    }
    if (loading) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator.adaptive()),
          ),
        ),
      );
    } else if (!hasResults && !failed) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              context.l10n.searchEmptyResultSubtitle,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    if (_selecting) {
      // Same reserve as the Library list, so the last rows can scroll clear
      // of the selection bar.
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 100)));
    }
    _visibleSongs = visibleSongs;
    if (_selecting || _selectionOverlay.isVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncSelectionBar());
    }
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _exitSelection();
      },
      child: SliverMainAxisGroup(slivers: slivers),
    );
  }
}
