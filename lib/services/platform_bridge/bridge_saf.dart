part of '../platform_bridge.dart';

/// Folder picked via the native iOS document picker: the filesystem path plus
/// the security-scoped bookmark that re-grants access across app launches.
class IosPickedDirectory {
  final String path;
  final String bookmark;

  const IosPickedDirectory({required this.path, required this.bookmark});
}

class IosSecurityScopedAccess {
  final String path;
  final String token;

  const IosSecurityScopedAccess({required this.path, required this.token});
}

class ContentUriPlaybackLease {
  final String path;
  final String token;

  final String? displayName;

  const ContentUriPlaybackLease({
    required this.path,
    required this.token,
    this.displayName,
  });
}
