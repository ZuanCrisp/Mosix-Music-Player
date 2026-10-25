import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/app.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, null);
  });

  group('restored installation detection', () {
    test('fresh package plus persisted settings requires a reset', () {
      const installState = InstallationState(
        markerExisted: false,
        markerCreated: true,
        freshPackageInstall: true,
      );

      expect(
        shouldResetRestoredInstallation(
          hasPersistedSettings: true,
          installState: installState,
        ),
        isTrue,
      );
      expect(
        shouldResetRestoredInstallation(
          hasPersistedSettings: false,
          installState: installState,
        ),
        isFalse,
      );
    });

    test('normal upgrade without the new marker preserves settings', () {
      const installState = InstallationState(
        markerExisted: false,
        markerCreated: true,
        freshPackageInstall: false,
      );

      expect(
        shouldResetRestoredInstallation(
          hasPersistedSettings: true,
          installState: installState,
        ),
        isFalse,
      );
    });

    test('marker creation failure never triggers a repeated reset', () {
      const installState = InstallationState(
        markerExisted: false,
        markerCreated: false,
        freshPackageInstall: true,
      );

      expect(
        shouldResetRestoredInstallation(
          hasPersistedSettings: true,
          installState: installState,
        ),
        isFalse,
      );
    });

    test('subsequent launch with a marker preserves settings', () {
      const installState = InstallationState(
        markerExisted: true,
        markerCreated: true,
        freshPackageInstall: false,
      );

      expect(
        shouldResetRestoredInstallation(
          hasPersistedSettings: true,
          installState: installState,
        ),
        isFalse,
      );
    });
  });

  group('restored settings sanitization', () {
    const restored = AppSettings(
      defaultService: 'extension.lossless',
      audioQuality: 'HI_RES_LOSSLESS',
      locale: 'id',
      downloadDirectory: '/storage/emulated/0/Music/Old',
      downloadDirectoryBookmark: 'old-bookmark',
      storageMode: 'saf',
      downloadTreeUri: 'content://tree/old',
      isFirstLaunch: false,
      useAllFilesAccess: true,
      localLibraryEnabled: true,
      localLibraryPath: 'content://tree/library',
      localLibraryBookmark: 'library-bookmark',
      localLibraryAutoScan: 'daily',
      hasCompletedTutorial: true,
    );

    test('resets installation-bound fields and keeps portable preferences', () {
      final sanitized = resetInstallationBoundSettings(restored);

      expect(sanitized.isFirstLaunch, isTrue);
      expect(sanitized.hasCompletedTutorial, isFalse);
      expect(sanitized.storageMode, 'app');
      expect(sanitized.downloadTreeUri, isEmpty);
      expect(sanitized.downloadDirectory, isEmpty);
      expect(sanitized.downloadDirectoryBookmark, isEmpty);
      expect(sanitized.useAllFilesAccess, isFalse);
      expect(sanitized.localLibraryEnabled, isFalse);
      expect(sanitized.localLibraryPath, isEmpty);
      expect(sanitized.localLibraryBookmark, isEmpty);
      expect(sanitized.localLibraryAutoScan, 'off');
      expect(sanitized.defaultService, restored.defaultService);
      expect(sanitized.audioQuality, restored.audioQuality);
      expect(sanitized.locale, restored.locale);
    });

    test('persists the sanitized state before bootstrap routing', () async {
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode(restored.toJson()),
      });
      final prefs = await SharedPreferences.getInstance();

      expect(hasPersistedAppSettings(prefs), isTrue);
      await resetRestoredInstallationSettings(prefs);
      final bootstrap = loadBootstrapSettings(prefs);

      expect(bootstrap.isFirstLaunch, isTrue);
      expect(bootstrap.storageMode, 'app');
      expect(bootstrap.downloadTreeUri, isEmpty);
      expect(bootstrap.defaultService, restored.defaultService);
    });
  });

  group('bootstrap routing', () {
    test('restored-install reset routes through setup and tutorial', () {
      final sanitized = resetInstallationBoundSettings(
        const AppSettings(
          isFirstLaunch: false,
          hasCompletedTutorial: true,
          storageMode: 'saf',
          downloadTreeUri: 'content://tree/old',
        ),
      );

      expect(
        initialLocationForAppState(
          isFirstLaunch: sanitized.isFirstLaunch,
          hasCompletedTutorial: sanitized.hasCompletedTutorial,
        ),
        '/setup',
      );
      expect(
        initialLocationForAppState(
          isFirstLaunch: false,
          hasCompletedTutorial: false,
        ),
        '/tutorial',
      );
      expect(
        initialLocationForAppState(
          isFirstLaunch: false,
          hasCompletedTutorial: true,
        ),
        '/',
      );
    });
  });

  group('strict SAF validation', () {
    test('returns the native persisted-grant result', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            expect(call.method, 'isSafTreeAccessible');
            expect(
              (call.arguments as Map)['tree_uri'],
              'content://tree/missing',
            );
            return false;
          });

      expect(
        await PlatformBridge.validateSafTreeAccess('content://tree/missing'),
        isFalse,
      );
    });

    test('surfaces bridge errors instead of allowing an unverified write', () {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            throw PlatformException(code: 'bridge_failure');
          });

      expect(
        PlatformBridge.validateSafTreeAccess('content://tree/missing'),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  test('Android backup policy excludes every app-data domain', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final currentRules = File(
      'android/app/src/main/res/xml/backup_rules.xml',
    ).readAsStringSync();
    final legacyRules = File(
      'android/app/src/main/res/xml/backup_rules_legacy.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:allowBackup="false"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/backup_rules"'),
    );
    expect(
      manifest,
      contains('android:fullBackupContent="@xml/backup_rules_legacy"'),
    );

    for (final domain in [
      'root',
      'file',
      'database',
      'sharedpref',
      'external',
      'device_root',
      'device_file',
      'device_database',
      'device_sharedpref',
    ]) {
      expect(currentRules, contains('domain="$domain" path="."'));
      expect(legacyRules, contains('domain="$domain" path="."'));
    }
    expect(currentRules, contains('<cloud-backup>'));
    expect(currentRules, contains('<device-transfer>'));
  });
}
