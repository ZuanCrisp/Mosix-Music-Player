import 'dart:collection';

/// Album order shared by playback, metadata navigation, and disc sections.
/// Missing disc tags belong to disc 1; missing track tags use 999.
class AlbumTrackOrder<T> {
  final List<T> tracks;
  final Map<int, List<T>> discGroups;
  final List<int> discNumbers;

  AlbumTrackOrder._(this.tracks, this.discGroups, this.discNumbers);

  factory AlbumTrackOrder(
    Iterable<T> items, {
    required int? Function(T) discNumber,
    required int? Function(T) trackNumber,
    required String Function(T) trackName,
  }) {
    final tracks = items.toList();
    tracks.sort((a, b) {
      final disc = (discNumber(a) ?? 1).compareTo(discNumber(b) ?? 1);
      if (disc != 0) return disc;
      final number = (trackNumber(a) ?? 999).compareTo(trackNumber(b) ?? 999);
      return number != 0 ? number : trackName(a).compareTo(trackName(b));
    });
    final discGroups = <int, List<T>>{};
    for (final track in tracks) {
      discGroups.putIfAbsent(discNumber(track) ?? 1, () => []).add(track);
    }
    return AlbumTrackOrder._(
      UnmodifiableListView(tracks),
      UnmodifiableMapView({
        for (final entry in discGroups.entries)
          entry.key: UnmodifiableListView(entry.value),
      }),
      UnmodifiableListView(discGroups.keys.toList()..sort()),
    );
  }
}
