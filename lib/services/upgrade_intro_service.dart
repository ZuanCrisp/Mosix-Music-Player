import 'package:shared_preferences/shared_preferences.dart';

/// Separate from settings migrations: migrating preferences must not consume
/// the upgrade introduction before the user has actually seen it.
class UpgradeIntroService {
  static const _seenKey = 'upgrade_intro_5_0_seen';

  static bool shouldShow(
    SharedPreferences preferences, {
    required String version,
    required bool existingInstallation,
  }) =>
      version.split('.').first == '5' &&
      existingInstallation &&
      !(preferences.getBool(_seenKey) ?? false);

  static Future<void> markSeen(SharedPreferences preferences) async {
    await preferences.setBool(_seenKey, true);
  }
}
