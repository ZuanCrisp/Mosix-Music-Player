import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/services/extension_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Map<String, String> values;
  late List<MethodCall> mutations;
  Object? readError;
  const keyName = 'extension_storage_master_key_v2';

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    ExtensionStorageService.resetForTesting();
    root = await Directory.systemTemp.createTemp('extension-storage-');
    values = {};
    mutations = [];
    readError = null;
    messenger.setMockMethodCallHandler(
      paths,
      (call) async =>
          '${root.path}/${call.method == 'getApplicationSupportDirectory' ? 'support' : 'documents'}',
    );
    messenger.setMockMethodCallHandler(secure, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final options = Map<String, dynamic>.from(args['options'] as Map);
      expect(options['resetOnError'], 'false');
      expect(options['migrateWithBackup'], 'true');
      if (call.method == 'read') {
        if (readError != null) throw readError!;
        return values[args['key']];
      }
      mutations.add(call);
      if (call.method == 'write') {
        values[args['key'] as String] = args['value'] as String;
      }
      return null;
    });
  });
  tearDown(() async {
    ExtensionStorageService.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(secure, null);
    await root.delete(recursive: true);
  });

  Future<File> seed(String relative, List<int> bytes) async {
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  test(
    'upgrade retains the same key and migrates encrypted files intact',
    () async {
      final key = base64Encode(List.filled(32, 7));
      values[keyName] = key;
      for (final name in ['settings.enc', '.credentials.enc', '.cred_salt']) {
        await seed('documents/extension_data/example.provider/$name', [
          1,
          2,
          3,
          4,
        ]);
      }
      final storage = await ExtensionStorageService.prepare();
      expect(storage.masterKey, key);
      expect(mutations, isEmpty);
      for (final name in ['settings.enc', '.credentials.enc', '.cred_salt']) {
        expect(
          await File('${storage.dataDir}/example.provider/$name').readAsBytes(),
          [1, 2, 3, 4],
        );
      }
    },
  );

  test('missing key never replaces encrypted settings and can retry', () async {
    final file = await seed(
      'support/extension_data/example.provider/settings.enc',
      [5, 6, 7],
    );
    await expectLater(
      ExtensionStorageService.prepare(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('key is missing'),
        ),
      ),
    );
    expect(mutations, isEmpty);
    expect(await file.readAsBytes(), [5, 6, 7]);
    final key = base64Encode(List.filled(32, 9));
    values[keyName] = key;
    expect((await ExtensionStorageService.prepare()).masterKey, key);
    expect(mutations, isEmpty);
  });

  for (final invalid in [
    'not-base64',
    base64Encode([1, 2, 3]),
  ]) {
    test('malformed key is preserved ($invalid)', () async {
      values[keyName] = invalid;
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<StateError>()),
      );
      expect(mutations, isEmpty);
      expect(values[keyName], invalid);
    });
  }

  test(
    'keystore failure propagates without deleting data and is retryable',
    () async {
      readError = PlatformException(code: 'keystore_unavailable');
      await expectLater(
        ExtensionStorageService.prepare(),
        throwsA(isA<PlatformException>()),
      );
      expect(mutations, isEmpty);
      readError = null;
      values[keyName] = base64Encode(List.filled(32, 3));
      expect(
        (await ExtensionStorageService.prepare()).masterKey,
        values[keyName],
      );
      expect(mutations, isEmpty);
    },
  );

  for (final legacy in [false, true]) {
    test(
      'fresh installs and plaintext legacy settings can create a key (legacy=$legacy)',
      () async {
        if (legacy) {
          await seed(
            'documents/extension_data/example.provider/settings.json',
            utf8.encode('{"region":"example"}'),
          );
          await seed(
            'documents/extension_data/example.provider/.cred_salt',
            List.filled(32, 1),
          );
        }
        final first = ExtensionStorageService.prepare();
        expect(identical(first, ExtensionStorageService.prepare()), isTrue);
        final storage = await first;
        expect(base64Decode(storage.masterKey), hasLength(32));
        expect(values[keyName], storage.masterKey);
        expect(mutations.map((call) => call.method), ['write']);
        if (legacy) {
          expect(
            await File(
              '${storage.dataDir}/example.provider/settings.json',
            ).readAsString(),
            '{"region":"example"}',
          );
        }
      },
    );
  }
}
