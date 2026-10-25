import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';

/// Call only after deletion succeeds. A download can also have a scanned row;
/// removing just one index makes its other row visible as a ghost entry.
/// Capture the app container before I/O so leaving the screen cannot prevent
/// cleanup after a slow network deletion.
Future<void> removeDeletedLibraryFileEntries(
  ProviderContainer container,
  Iterable<String> filePaths,
) async {
  final paths = filePaths.toSet();
  if (paths.isEmpty) return;
  await container
      .read(downloadHistoryProvider.notifier)
      .removePhysicalFiles(paths);
  await container
      .read(localLibraryProvider.notifier)
      .removePhysicalFiles(paths);
}
