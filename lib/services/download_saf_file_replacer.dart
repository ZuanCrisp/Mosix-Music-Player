import 'dart:io';

typedef SafFileOperation =
    Future<(String path, String fileName)?> Function(
      String tempPath,
      void Function(String path) addCleanup,
    );

typedef ReplaceSafDownloadFile =
    Future<String?> Function({
      required String uri,
      required String treeUri,
      required String relativeDir,
      required SafFileOperation op,
      bool avoidOverwrite,
      void Function(String fileName)? onPublishedFileName,
    });

typedef PublishSafDownloadFile =
    Future<({String uri, String fileName})?> Function({
      required String treeUri,
      required String relativeDir,
      required String fileName,
      required String srcPath,
      required bool avoidOverwrite,
      required String preservedSuffix,
      String? collisionCleanFileName,
      String? collisionVariantFileName,
    });

/// Owns temporary files for a SAF transform. Publication must succeed before
/// removing the source URI, including transforms that change the filename.
class DownloadSafFileReplacer {
  const DownloadSafFileReplacer({
    required this.copyToTemp,
    required this.publish,
    required this.deleteSource,
  });

  final Future<String?> Function(String uri) copyToTemp;
  final PublishSafDownloadFile publish;
  final Future<void> Function(String uri) deleteSource;

  Future<String?> replace({
    required String uri,
    required String treeUri,
    required String relativeDir,
    required SafFileOperation op,
    bool avoidOverwrite = false,
    String preservedSuffix = '',
    String? collisionCleanFileName,
    String? collisionVariantFileName,
    void Function(String fileName)? onPublishedFileName,
  }) async {
    final tempPath = await copyToTemp(uri);
    if (tempPath == null) return null;
    final cleanup = <String>{tempPath};
    try {
      final produced = await op(tempPath, cleanup.add);
      if (produced == null) return null;
      cleanup.add(produced.$1);
      final published = await publish(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: produced.$2,
        srcPath: produced.$1,
        avoidOverwrite: avoidOverwrite,
        preservedSuffix: preservedSuffix,
        collisionCleanFileName: collisionCleanFileName,
        collisionVariantFileName: collisionVariantFileName,
      );
      if (published == null) return null;
      onPublishedFileName?.call(published.fileName);
      if (published.uri != uri) await deleteSource(uri);
      return published.uri;
    } finally {
      for (final path in cleanup) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }
}
