import 'mornye_artwork_performance_test.dart' as artwork;
import 'mornye_lyrics_performance_test.dart' as lyrics;
import 'mornye_rendering_performance_test.dart' as rendering;
import 'mornye_screens_performance_test.dart' as screens;
import 'performance_probe.dart';

void main() {
  PerformanceTestBinding.ensureInitialized();
  rendering.main();
  screens.main();
  artwork.main();
  lyrics.main();
}
