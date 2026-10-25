import 'package:mornye/utils/file_access.dart';

sealed class FileAccessCheck {
  const FileAccessCheck();
}

final class FileAccessFound extends FileAccessCheck {
  const FileAccessFound(this.stat);

  final FileAccessStat stat;
}

final class FileAccessMissing extends FileAccessCheck {
  const FileAccessMissing();
}

final class FileAccessUnavailable extends FileAccessCheck {
  const FileAccessUnavailable(this.error, this.stack);

  final Object error;
  final StackTrace stack;
}

/// Only a confirmed missing result may be presented as a deleted file.
/// Provider and permission failures retain their diagnostic cause.
Future<FileAccessCheck> checkFileAccess(
  String path, {
  Future<FileAccessStat?> Function(String?) readStat = fileStat,
}) async {
  try {
    final stat = await readStat(path);
    return stat == null ? const FileAccessMissing() : FileAccessFound(stat);
  } catch (error, stack) {
    return FileAccessUnavailable(error, stack);
  }
}
