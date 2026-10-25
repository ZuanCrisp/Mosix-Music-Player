import 'package:shared_preferences/shared_preferences.dart';

/// Remembers that the one-time SAF migration prompt was already shown.
class SafMigrationPromptStore {
  const SafMigrationPromptStore();

  static const _shownKey = 'saf_migration_prompt_shown';

  Future<bool> wasShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_shownKey) == true;
  }

  Future<void> markShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shownKey, true);
  }
}
