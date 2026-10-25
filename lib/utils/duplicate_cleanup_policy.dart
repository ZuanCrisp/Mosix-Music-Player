import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/utils/path_match_keys.dart';

/// Clear every index of a deleted file, but never delete a retained alias.
Future<int> deleteReviewedDuplicateCopies({
  required List<IsrcDuplicateEntry> entries,
  required List<IsrcDuplicateEntry> retainedEntries,
  required Future<bool> Function(String path) deleteFile,
  required Future<void> Function(String path) removePhysicalFile,
  required Future<void> Function(IsrcDuplicateEntry entry) removeIndexEntry,
}) async {
  var deleted = 0;
  for (final entry in entries) {
    final path = DownloadedEmbeddedCoverResolver.cleanFilePath(entry.filePath);
    if (isPhysicalFileRetained(
      path,
      retainedEntries.map((entry) => entry.filePath),
    )) {
      await removeIndexEntry(entry);
    } else {
      if (!await deleteFile(path)) continue;
      await removePhysicalFile(entry.filePath);
    }
    deleted++;
  }
  return deleted;
}

class DuplicateCleanupPlan {
  final List<IsrcDuplicateEntry> retainedEntries;
  final List<IsrcDuplicateEntry> entriesToDelete;
  final int groupCount;

  const DuplicateCleanupPlan({
    required this.retainedEntries,
    required this.entriesToDelete,
    required this.groupCount,
  });
}

/// Keeps the first (highest-quality) entry from every duplicate group and
/// schedules every remaining copy for deletion.
///
/// [LibraryDatabase.findIsrcDuplicateGroups] returns entries best-quality
/// first, so this policy deliberately preserves that ordering contract.
DuplicateCleanupPlan buildKeepBestAllDuplicatePlan(
  List<IsrcDuplicateGroup> groups,
) {
  final retainedEntries = <IsrcDuplicateEntry>[];
  final entriesToDelete = <IsrcDuplicateEntry>[];
  var groupCount = 0;

  for (final group in groups) {
    if (group.entries.length < 2) continue;
    groupCount++;
    retainedEntries.add(group.entries.first);
    entriesToDelete.addAll(group.entries.skip(1));
  }

  return DuplicateCleanupPlan(
    retainedEntries: List.unmodifiable(retainedEntries),
    entriesToDelete: List.unmodifiable(entriesToDelete),
    groupCount: groupCount,
  );
}
