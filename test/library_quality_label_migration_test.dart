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

  Future<String> load(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).ensureLoaded();
    return container.read(settingsProvider).libraryQualityLabelMode;
  }

  String persisted(String mode) =>
      jsonEncode(AppSettings(libraryQualityLabelMode: mode).toJson());

  test('the persisted bitrate default returns to bit depth once', () async {
    expect(
      await load({
        'app_settings': persisted(AppSettings.libraryQualityLabelBitrate),
        'settings_migration_version': 11,
      }),
      AppSettings.libraryQualityLabelBitDepthOnly,
    );
  });

  test('bitrate chosen after the migration is kept', () async {
    expect(
      await load({
        'app_settings': persisted(AppSettings.libraryQualityLabelBitrate),
        'settings_migration_version': 12,
      }),
      AppSettings.libraryQualityLabelBitrate,
    );
  });

  test('other label modes survive the migration', () async {
    expect(
      await load({
        'app_settings': persisted(AppSettings.libraryQualityLabelFileFormat),
        'settings_migration_version': 11,
      }),
      AppSettings.libraryQualityLabelFileFormat,
    );
  });
}
