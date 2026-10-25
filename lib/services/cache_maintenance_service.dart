import 'dart:io';

class DirectoryStats {
  final int fileCount;
  final int totalSizeBytes;

  const DirectoryStats({required this.fileCount, required this.totalSizeBytes});
}

/// Directory sizing and clearing for the cache management page.
abstract final class CacheMaintenanceService {
  static Future<DirectoryStats> scanDirectory(Directory directory) async {
    if (!await directory.exists()) {
      return const DirectoryStats(fileCount: 0, totalSizeBytes: 0);
    }

    var fileCount = 0;
    var totalSize = 0;

    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          fileCount++;
          totalSize += await entity.length();
        }
      }
    } catch (_) {}

    return DirectoryStats(fileCount: fileCount, totalSizeBytes: totalSize);
  }

  static Future<void> clearDirectoryContents(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return;

    try {
      final entities = <FileSystemEntity>[];
      await for (final entity in directory.list(followLinks: false)) {
        entities.add(entity);
      }

      const deleteChunkSize = 24;
      for (var i = 0; i < entities.length; i += deleteChunkSize) {
        final end = (i + deleteChunkSize < entities.length)
            ? i + deleteChunkSize
            : entities.length;
        final chunk = entities.sublist(i, end);
        await Future.wait(
          chunk.map((entity) async {
            try {
              await entity.delete(recursive: true);
            } catch (_) {}
          }),
        );
      }
    } catch (_) {}

    try {
      await directory.create(recursive: true);
    } catch (_) {}
  }
}
