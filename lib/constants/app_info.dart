import 'package:flutter/foundation.dart';

class AppInfo {
  static const String version = '1.0.0';
  static const String buildNumber = '1';

  static const String gitCommit = String.fromEnvironment('GIT_COMMIT');
  static String get shortGitCommit =>
      gitCommit.length > 8 ? gitCommit.substring(0, 8) : gitCommit;

  static String get displayVersion => kDebugMode ? 'Internal' : version;

  static const String appName = 'Mosix';
  static const String copyright = '© 2026 ZuanCrisp';

  static const String mobileAuthor = 'ZuanCrisp';

  static const String githubRepo = 'ZuanCrisp/Mosix-Music-Player';
  static const String githubUrl = 'https://github.com/$githubRepo';
  static const String remoteConfigApiUrl = '';

  static const String kofiUrl = '';
  static const String githubSponsorsUrl = '';
}
