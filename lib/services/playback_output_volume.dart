import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('OutputVolume');

/// Keeps [playbackOutputVolume] across launches on desktop, where it takes
/// the place of the system volume. Mobile never moves it from 1.
abstract final class PlaybackOutputVolumeStore {
  static const storageKey = 'playback_output_volume_v1';
  static const _saveDelay = Duration(milliseconds: 300);

  static Future<void>? _restore;
  static Timer? _saveTimer;

  /// Loads the saved volume once, then saves later changes. A change made
  /// while the value loads wins over the saved one.
  static Future<void> ensureRestored() => _restore ??= _load();

  static Future<void> _load() async {
    var changed = false;
    void track() => changed = true;
    playbackOutputVolume.addListener(track);
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(storageKey);
      if (!changed && saved != null && saved.isFinite) {
        playbackOutputVolume.value = saved.clamp(0.0, 1.0);
      }
    } catch (error) {
      _log.w('Could not read the saved volume: $error');
    } finally {
      playbackOutputVolume.removeListener(track);
    }
    playbackOutputVolume.addListener(_scheduleSave);
  }

  static void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(_save()));
  }

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(storageKey, playbackOutputVolume.value);
    } catch (error) {
      _log.w('Could not save the volume: $error');
    }
  }

  /// Saves a pending change now, for tests.
  @visibleForTesting
  static Future<void> debugFlush() async {
    if (_saveTimer?.isActive != true) return;
    _saveTimer!.cancel();
    await _save();
  }

  @visibleForTesting
  static void debugReset() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _restore = null;
    playbackOutputVolume.removeListener(_scheduleSave);
  }
}
