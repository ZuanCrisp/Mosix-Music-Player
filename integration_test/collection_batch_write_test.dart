import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'loved_batch_write_test.dart' as loved;
import 'playlist_batch_write_test.dart' as playlists;

void main() {
  // Register the driver's completion hook outside either fixture group.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('Playlist batches', playlists.main);
  group('Loved batches', loved.main);
}
