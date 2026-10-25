import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() {
    messenger.setMockMethodCallHandler(secure, (call) async => null);
  });
  tearDownAll(() => messenger.setMockMethodCallHandler(secure, null));

  Future<List<String>> load(List<String> providers, int migration) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(
        AppSettings(lyricsProviders: providers).toJson(),
      ),
      'settings_migration_version': migration,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).ensureLoaded();
    return container.read(settingsProvider).lyricsProviders;
  }

  test('the untouched legacy default moves to the new defaults', () async {
    expect(
      await load(['apple_music', 'lrclib'], 12),
      const AppSettings().lyricsProviders,
    );
  });

  test('a custom order keeps the former fallback after Apple Music', () async {
    expect(await load(['lrclib', 'apple_music', 'netease'], 12), [
      'lrclib',
      'apple_music',
      'mornye_lyrics',
      'netease',
    ]);
  });

  test('renames the saved provider while keeping a custom order', () async {
    expect(await load(['lrclib', 'spotiflac_lyrics', 'apple_music'], 13), [
      'lrclib',
      'mornye_lyrics',
      'apple_music',
    ]);
  });

  test('orders without Apple Music are left alone', () async {
    expect(await load(['lrclib', 'netease'], 12), ['lrclib', 'netease']);
  });

  test('choices made after the migration are kept', () async {
    expect(await load(['apple_music', 'lrclib'], 13), [
      'apple_music',
      'lrclib',
    ]);
  });
}
