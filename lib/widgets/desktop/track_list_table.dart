import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';
import 'package:mornye/widgets/track_list_tile.dart';

/// The desktop song table for album, playlist and folder [Track] lists, in
/// place of
/// [TrackListTile] rows. Right-click opens the track options; a click and
/// Enter run [onActivate], which should match a tap on a mobile row (see
/// [TrackListTile.activate]).
class TrackListTable extends ConsumerWidget {
  const TrackListTable({
    super.key,
    required this.tracks,
    required this.ids,
    required this.isInHistory,
    required this.selectedIds,
    required this.onSelect,
    required this.onActivate,
    this.onContextMenu,
    this.showArtwork = false,
    this.showAlbum = false,
    this.albumLayout = false,
    this.albumArtist,
  });

  /// See [SliverTrackTable.albumLayout] and [SliverTrackTable.albumArtist].
  final bool albumLayout;
  final String? albumArtist;

  final List<Track> tracks;

  /// Selection id of each track, by index.
  final List<String> ids;

  /// Whether each track, by index, is in the download history.
  final List<bool> isInHistory;
  final Set<String> selectedIds;
  final void Function(String id, DesktopClick kind, List<String> orderedIds)
  onSelect;

  /// Runs the row at this index.
  final ValueChanged<int> onActivate;

  /// Opens the menu of the row at this index. Defaults to the track options
  /// of the row's ellipsis button.
  final void Function(int index, Offset position)? onContextMenu;

  /// Playlists show artwork and the album; albums show track numbers.
  final bool showArtwork;
  final bool showAlbum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indexById = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final rows = [
      for (var i = 0; i < tracks.length; i++)
        TrackTableRow(
          id: ids[i],
          number: showArtwork ? i + 1 : tracks[i].trackNumber,
          title: tracks[i].name,
          artist: tracks[i].artistName,
          album: tracks[i].albumName,
          quality: tracks[i].audioQuality,
          duration: tracks[i].duration > 0
              ? Duration(seconds: tracks[i].duration)
              : null,
          leading: showArtwork ? _Artwork(url: tracks[i].coverUrl) : null,
          titleTrailing: TrackListTileBadges(
            track: tracks[i],
            isInHistory: isInHistory[i],
          ),
          trailing: TrackCollectionQuickActions(
            track: tracks[i],
            hasLocalPlaybackCandidate: isInHistory[i],
            dense: true,
          ),
          playback: catalogTrackPlaybackUiProvider(catalogTrackKey(tracks[i])),
        ),
    ];
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverTrackTable(
        rows: rows,
        columns: [
          TrackTableColumn.number,
          TrackTableColumn.title,
          TrackTableColumn.artist,
          if (showAlbum) TrackTableColumn.album,
          // Catalog pages often list no quality before a download.
          if (rows.any((row) => row.quality?.isNotEmpty ?? false))
            TrackTableColumn.quality,
          TrackTableColumn.duration,
        ],
        selectedIds: selectedIds,
        albumLayout: albumLayout,
        albumArtist: albumArtist,
        onSelect: onSelect,
        onActivate: (id) {
          final index = indexById[id];
          if (index != null) onActivate(index);
        },
        onContextMenu: (id, position) {
          final index = indexById[id];
          if (index == null) return;
          final override = onContextMenu;
          if (override != null) return override(index, position);
          TrackCollectionQuickActions.showTrackOptionsSheet(
            context,
            ref,
            tracks[index],
            position: position,
            hasLocalPlaybackCandidate: isInHistory[index],
          );
        },
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    if (url == null || url.isEmpty) {
      return const TrackCoverPlaceholder(size: 32);
    }
    // Collection tracks can carry a local artwork path.
    return LocalOrNetworkCoverImage(
      url: url,
      width: 32,
      height: 32,
      borderRadius: BorderRadius.circular(4),
      networkCacheWidth: 96,
      localCacheWidth: 96,
      placeholder: (_) => const TrackCoverPlaceholder(size: 32),
    );
  }
}
