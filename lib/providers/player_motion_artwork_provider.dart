import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/motion_artwork_store.dart';

typedef PlayerArtworkAlbum = ({String album, String artist});

final motionArtworkStoreProvider = Provider((ref) => MotionArtworkStore());

/// Player and local album pages read artwork already saved with a download.
/// Opening either must never search extensions or download more artwork.
final playerMotionArtworkProvider = FutureProvider.autoDispose
    .family<MotionArtwork?, PlayerArtworkAlbum>((ref, album) async {
      if (!ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
        return null;
      }
      if (album.album.trim().isEmpty || album.artist.trim().isEmpty) {
        return null;
      }
      return ref.watch(motionArtworkStoreProvider).find(album);
    });
