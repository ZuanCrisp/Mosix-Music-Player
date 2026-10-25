import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists the first-run setup draft so an interrupted setup can resume.
class SetupProgressStore {
  SetupProgressStore() : _prefs = SharedPreferences.getInstance();

  static const _progressKey = 'setup_progress_v1';

  final Future<SharedPreferences> _prefs;

  /// The stored draft as raw JSON text, or null when none was saved.
  Future<String?> readDraft() async => (await _prefs).getString(_progressKey);

  Future<void> writeDraft(Map<String, Object?> draft) async {
    final encoded = jsonEncode(draft);
    if (!await (await _prefs).setString(_progressKey, encoded)) {
      throw StateError('Could not save setup progress');
    }
  }

  Future<void> clear() async {
    await (await _prefs).remove(_progressKey);
  }
}
