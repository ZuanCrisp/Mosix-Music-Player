/// Canonical service / provider identifiers shared across the app.
///
/// These values must stay in sync with the provider ids reported by the Go
/// backend and by extensions; use them instead of raw string literals when
/// comparing or dispatching on a service id.
abstract final class MusicServices {
  static const spotify = 'spotify';
  static const deezer = 'deezer';
  static const tidal = 'tidal';
  static const qobuz = 'qobuz';
  static const amazon = 'amazon';

  /// Pseudo-service for tracks that only exist in the local library.
  static const local = 'local';
}
