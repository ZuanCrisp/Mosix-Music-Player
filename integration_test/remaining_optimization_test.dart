import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'download_queue_workers_test.dart' as queue;
import 'library_collections_workers_test.dart' as collections;
import 'native_backup_archive_test.dart' as archive;
import 'native_cache_maintenance_test.dart' as cache;
import 'native_collection_restore_test.dart' as restore;
import 'native_history_snapshot_test.dart' as history;
import 'native_library_staging_test.dart' as library_staging;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('collection restore', restore.main);
  group('history staging', history.main);
  group('library staging', library_staging.main);
  group('cache maintenance', cache.main);
  group('collection workers', collections.main);
  group('queue workers', queue.main);
  group('backup archive', archive.main);
}
