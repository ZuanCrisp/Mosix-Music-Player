import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_decryption.dart';
import 'package:mornye/services/ffmpeg_models.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('decryption-output-');
  });
  tearDown(() async => directory.delete(recursive: true));

  DownloadDecryptionDescriptor descriptor(String extension) =>
      DownloadDecryptionDescriptor(
        strategy: 'ffmpeg.mov_key',
        key: '00112233445566778899aabbccddeeff',
        outputExtension: extension,
      );

  String outputPath(String command) =>
      FFmpegKitConfig.parseArguments(command).reversed.skip(1).first;

  Future<FFmpegResult> succeed(String command) async {
    await File(outputPath(command)).writeAsString('decrypted');
    return FFmpegResult(success: true, returnCode: 0, output: '');
  }

  for (final name in [
    'Song.flac',
    'Song.m4a',
    'Song.mp4',
    'Song_converted.flac',
  ]) {
    test('decryption retains the original name $name', () async {
      final source = await File(
        '${directory.path}/$name',
      ).writeAsString('encrypted');
      final result = await FFmpegDecryption.decrypt(
        inputPath: source.path,
        descriptor: descriptor(
          '.${source.uri.pathSegments.last.split('.').last}',
        ),
        execute: (command) async {
          expect(outputPath(command), isNot(source.path));
          expect(await source.readAsString(), 'encrypted');
          return succeed(command);
        },
      );
      expect(result, source.path);
      expect(await source.readAsString(), 'decrypted');
      expect(await directory.list().length, 1);
    });
  }

  test('failed FLAC attempt falls back to the original M4A name', () async {
    final source = await File(
      '${directory.path}/Song.m4a',
    ).writeAsString('encrypted');
    String? failedPath;
    final result = await FFmpegDecryption.decrypt(
      inputPath: source.path,
      descriptor: descriptor('.flac'),
      execute: (command) async {
        expect(await source.readAsString(), 'encrypted');
        if (outputPath(command).endsWith('.flac')) {
          failedPath = outputPath(command);
          await File(failedPath!).writeAsString('partial');
          return FFmpegResult(
            success: false,
            returnCode: 1,
            output: 'unsupported codec',
          );
        }
        expect(await File(failedPath!).exists(), isFalse);
        return succeed(command);
      },
    );
    expect(result, source.path);
    expect(await source.readAsString(), 'decrypted');
    expect(await directory.list().length, 1);
  });

  test(
    'decryption failures and exceptions retain the source and clean outputs',
    () async {
      final source = await File(
        '${directory.path}/Song.flac',
      ).writeAsString('encrypted');
      for (final execute in <Future<FFmpegResult> Function(String)>[
        (command) async {
          await File(outputPath(command)).writeAsString('partial');
          return FFmpegResult(success: false, returnCode: 1, output: 'bad key');
        },
        (_) async => throw StateError('execution failed'),
        (_) async => FFmpegResult(success: true, returnCode: 0, output: ''),
      ]) {
        expect(
          await FFmpegDecryption.decrypt(
            inputPath: source.path,
            descriptor: descriptor('.flac'),
            execute: execute,
          ),
          isNull,
        );
        expect(await source.readAsString(), 'encrypted');
        expect(await directory.list().length, 1);
      }
    },
  );

  test(
    'decryption preserves an existing output and a requested original',
    () async {
      final source = await File(
        '${directory.path}/Song.m4a',
      ).writeAsString('encrypted');
      final sibling = await File(
        '${directory.path}/Song.flac',
      ).writeAsString('existing');
      final result = await FFmpegDecryption.decrypt(
        inputPath: source.path,
        descriptor: descriptor('.flac'),
        deleteOriginal: false,
        execute: succeed,
      );
      expect(result, '${directory.path}/Song (2).flac');
      expect(await source.readAsString(), 'encrypted');
      expect(await sibling.readAsString(), 'existing');
      expect(await File(result!).readAsString(), 'decrypted');
    },
  );

  test(
    'container preparation completes while the original is available',
    () async {
      final source = await File(
        '${directory.path}/Song.mp4',
      ).writeAsString('encrypted');
      final result = await FFmpegDecryption.decrypt(
        inputPath: source.path,
        descriptor: descriptor('.mp4'),
        execute: succeed,
        prepareOutput: (path) async {
          expect(await source.readAsString(), 'encrypted');
          await File(path).writeAsString('repaired');
        },
      );
      expect(result, source.path);
      expect(await source.readAsString(), 'repaired');
      expect(await directory.list().length, 1);
    },
  );

  test(
    'encrypted audio round trip keeps its name and remains decodable',
    () async {
      final source = File('${directory.path}/Song.m4a');
      final key = descriptor('.m4a').key;
      ProcessResult generated;
      try {
        generated = await Process.run('ffmpeg', [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=0.2',
          '-c:a',
          'aac',
          '-encryption_scheme',
          'cenc-aes-ctr',
          '-encryption_key',
          key,
          '-encryption_kid',
          'ffeeddccbbaa99887766554433221100',
          source.path,
        ]);
      } on ProcessException {
        markTestSkipped('Host FFmpeg is unavailable');
        return;
      }
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      final result = await FFmpegDecryption.decrypt(
        inputPath: source.path,
        descriptor: descriptor('.m4a'),
        execute: (command) async {
          final result = await Process.run(
            'ffmpeg',
            FFmpegKitConfig.parseArguments(command),
          );
          return FFmpegResult(
            success: result.exitCode == 0,
            returnCode: result.exitCode,
            output: '${result.stderr}',
          );
        },
      );
      expect(result, source.path);
      final decoded = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-xerror',
        '-i',
        source.path,
        '-f',
        'null',
        '-',
      ]);
      expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
      expect(await directory.list().length, 1);
    },
  );
}
