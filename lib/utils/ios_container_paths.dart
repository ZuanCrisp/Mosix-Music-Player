final _iosSandboxRoot = RegExp(
  r'^(?:/private)?/var/mobile/Containers/Data/Application/[A-F0-9\-]+(?=/)'
  r'|^/[^\n]+/Library/Developer/CoreSimulator/Devices/[A-F0-9\-]+'
  r'/data/Containers/Data/Application/[A-F0-9\-]+(?=/)',
  caseSensitive: false,
);

/// Restores an app-owned path after iOS relocates the app's data container.
/// Bookmarked external folders must be resolved through their bookmark instead.
String rebaseIosSandboxPath(String path, String documentsPath) {
  final current = _iosSandboxRoot.firstMatch(documentsPath);
  final previous = _iosSandboxRoot.firstMatch(path);
  if (current == null ||
      previous == null ||
      documentsPath.substring(current.end) != '/Documents') {
    return path;
  }

  final suffix = path.substring(previous.end);
  const appDirectories = [
    '/Documents',
    '/Library/Application Support',
    '/Library/Caches',
  ];
  if (!appDirectories.any(
        (directory) => suffix == directory || suffix.startsWith('$directory/'),
      ) ||
      suffix.split('/').contains('..')) {
    return path;
  }
  return '${documentsPath.substring(0, current.end)}$suffix';
}
