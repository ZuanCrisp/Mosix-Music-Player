import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/hires_check_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  late Directory directory;
  late File original;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hires-replacement-');
    original = await File(
      '${directory.path}/track.flac',
    ).writeAsString('original audio');
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test('automatic replacement defaults off for new and existing settings', () {
    expect(const AppSettings().redownloadFakeHiRes, isFalse);
    expect(AppSettings.fromJson({}).redownloadFakeHiRes, isFalse);
    final enabled = const AppSettings().copyWith(redownloadFakeHiRes: true);
    expect(AppSettings.fromJson(enabled.toJson()).redownloadFakeHiRes, isTrue);
  });

  test(
    'finalization exception restores original over a partial replacement',
    () async {
      await expectLater(
        HiResCheckService.withOriginalBackup(original.path, (backup) async {
          expect(await File(backup).readAsString(), 'original audio');
          await original.writeAsString('incomplete replacement');
          throw StateError('finalization failed');
        }),
        throwsStateError,
      );
      expect(await original.readAsString(), 'original audio');
      expect(await directory.list().length, 1);
    },
  );

  test('pause or cancellation restores the original', () async {
    final success = await HiResCheckService.withOriginalBackup(original.path, (
      backup,
    ) async {
      await original.writeAsString('partial');
      return false;
    });
    expect(success, isFalse);
    expect(await original.readAsString(), 'original audio');
  });

  test(
    'backup survives until final publication and persistence complete',
    () async {
      final pending = Completer<bool>();
      final started = Completer<String>();
      final transaction = HiResCheckService.withOriginalBackup(original.path, (
        backup,
      ) async {
        await original.writeAsString('verified replacement');
        started.complete(backup);
        return pending.future;
      });
      final backup = await started.future;
      expect(await File(backup).readAsString(), 'original audio');
      pending.complete(true);
      expect(await transaction, isTrue);
      expect(await original.readAsString(), 'verified replacement');
      expect(await File(backup).exists(), isFalse);
    },
  );

  test('existing backup is never overwritten', () async {
    final oldBackup = await File(
      '${original.path}.fake-hires.bak',
    ).writeAsString('older original');
    await HiResCheckService.withOriginalBackup(
      original.path,
      (_) async => false,
    );
    expect(await oldBackup.readAsString(), 'older original');
    expect(await original.readAsString(), 'original audio');
  });

  test('failed restoration retains backup and reports its location', () async {
    String? backupPath;
    await expectLater(
      HiResCheckService.withOriginalBackup(original.path, (backup) async {
        backupPath = backup;
        await Directory(original.path).create();
        return false;
      }),
      throwsA(isA<HiResOriginalRestoreException>()),
    );
    expect(await File(backupPath!).readAsString(), 'original audio');
  });

  test(
    'verification requires explicit full-file success from the backend',
    () async {
      for (final reply in [
        {'supported': true, 'redownload_safe': true},
        {'replacement_equivalent': false},
        {'error': 'decode failed', 'replacement_equivalent': true},
        {'replacement_equivalent': true},
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'checkHiResAuthenticity');
              final arguments = call.arguments as Map<Object?, Object?>;
              expect(arguments['file_path'], 'original.flac');
              expect(jsonDecode(arguments['options_json'] as String), {
                'verify_replacement_path': 'replacement.flac',
              });
              return jsonEncode(reply);
            });
        expect(
          await HiResCheckService.replacementPreservesAudio(
            'original.flac',
            'replacement.flac',
          ),
          reply['replacement_equivalent'] == true && reply['error'] == null,
        );
      }
    },
  );
}
