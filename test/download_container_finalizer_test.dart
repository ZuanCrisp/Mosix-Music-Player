import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/services/download_container_finalizer.dart';
import 'package:mornye/services/download_saf_file_replacer.dart';
import 'package:mornye/services/ffmpeg_probe.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'container-finalization-',
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  DownloadContainerFinalizer finalizer({
    Future<String?> Function(String)? probe,
    Future<String?> Function(String)? convert,
    Future<String> Function(String)? rename,
    ReplaceSafDownloadFile? replaceSaf,
  }) => DownloadContainerFinalizer(
    probeCodec: probe ?? (_) async => throw StateError('Unexpected probe'),
    isNativeFlac: FFmpegProbe.isNativeFlacFile,
    ensureFlacExtension:
        rename ?? (_) async => throw StateError('Unexpected rename'),
    convertToFlac:
        convert ?? (_) async => throw StateError('Unexpected conversion'),
    replaceSafFile:
        replaceSaf ??
        ({
          required uri,
          required treeUri,
          required relativeDir,
          required op,
          avoidOverwrite = false,
          onPublishedFileName,
        }) async => throw StateError('Unexpected SAF access'),
    debug: (_) {},
  );

  Future<String?> finalize(
    DownloadContainerFinalizer stage,
    DownloadResult result, {
    String path = '/Song.m4a',
    String extension = '.flac',
    bool force = false,
    bool saf = false,
    Future<void> Function(String)? embed,
  }) => stage.finalize(
    result: result,
    filePath: path,
    requestedExtension: extension,
    forceConversion: force,
    useSaf: saf,
    treeUri: 'content://tree',
    relativeDir: 'Artist/Album',
    fallbackFileName: 'Song.m4a',
    embedMetadata: embed,
  );

  test('explicit non-FLAC requests bypass conversion', () async {
    for (final extension in ['.m4a', '.mp4', '.opus']) {
      expect(
        await finalize(
          finalizer(),
          DownloadResult.fromMap({'audio_codec': 'flac'}),
          extension: extension,
          force: true,
        ),
        '/Song.m4a',
      );
    }
  });

  test(
    'container hints cannot override measured FLAC or lossy audio',
    () async {
      final source = await File(
        '${directory.path}/Song.m4a',
      ).writeAsString('MP4');
      for (final codec in ['flac', 'aac', 'eac3']) {
        for (final raw in <Map<String, dynamic>>[
          {'audio_codec': 'm4a'},
          {'audio_codec': 'aac'},
          {'decryption_key': 'abcd', 'output_extension': '.mp4'},
        ]) {
          final result = DownloadResult.fromMap(raw);
          var converted = false;
          final stage = finalizer(
            probe: (_) async => codec,
            convert: (_) async {
              converted = true;
              return '${directory.path}/Song.flac';
            },
          );
          final path = await finalize(stage, result, path: source.path);
          expect(converted, codec == 'flac', reason: '$codec / $raw');
          expect(path, converted ? '${directory.path}/Song.flac' : source.path);
          if (converted) expect(result.outputExtension(), '.flac');
        }
      }
    },
  );

  test(
    'actual stream decisions follow the shared native conversion cases',
    () async {
      final source = await File(
        '${directory.path}/Song.m4a',
      ).writeAsString('MP4');
      for (final row in File(
        'android/app/src/test/resources/finalization_container_cases.tsv',
      ).readAsLinesSync()) {
        if (row.startsWith('#') || row.trim().isEmpty) continue;
        final fields = row.split('\t');
        var converted = false;
        final result = DownloadResult.fromMap({'unknown': 'retained'});
        final stage = finalizer(
          probe: (_) async => fields[1].isEmpty ? null : fields[1],
          convert: (_) async {
            converted = true;
            return '${directory.path}/Song.flac';
          },
        );
        final outcome = await finalize(
          stage,
          result,
          path: source.path,
          force: fields[0] == 'true',
        );
        expect(converted, fields[2] == 'true', reason: row);
        expect(
          outcome,
          converted ? '${directory.path}/Song.flac' : source.path,
        );
        expect(result.audioCodec, converted ? 'flac' : null);
        expect(result['unknown'], 'retained');
      }
    },
  );

  test(
    'FLAC-in-MP4 is remuxed while actual native FLAC is renamed and tagged',
    () async {
      for (final native in [false, true]) {
        final source = await File(
          '${directory.path}/Song.m4a',
        ).writeAsString(native ? 'fLaCaudio' : 'MP4audio');
        final events = <String>[];
        final stage = finalizer(
          probe: (_) async => 'flac',
          rename: (path) async {
            events.add('rename');
            return (await File(
              path,
            ).rename('${directory.path}/Song.flac')).path;
          },
          convert: (path) async {
            events.add('remux');
            final output = await File(
              '${directory.path}/Song.flac',
            ).writeAsString('fLaCaudio');
            await File(path).delete();
            return output.path;
          },
        );
        final result = DownloadResult.fromMap({
          'file_name': 'Song.m4a',
          'audio_codec': 'm4a',
          'decryption_key': 'abcd',
          'output_extension': '.mp4',
          'actual_container': 'mp4',
          'requires_container_conversion': true,
        });
        final path = await finalize(
          stage,
          result,
          path: source.path,
          embed: (path) async {
            expect(await FFmpegProbe.isNativeFlacFile(path), isTrue);
            events.add('tag');
          },
        );
        expect(path, '${directory.path}/Song.flac');
        expect(events, [native ? 'rename' : 'remux', 'tag']);
        expect(result.outputExtension(), '.flac');
        expect(result.fileName, 'Song.flac');
        expect(result.filePath, path);
        expect(result['actual_container'], 'flac');
        expect(result.requiresContainerConversion, isFalse);
        await File(path!).delete();
      }
    },
  );

  test(
    'deferred SAF keeps the logical name with the finalized FLAC suffix',
    () async {
      final source = await File(
        '${directory.path}/native_saf_work_123.m4a',
      ).writeAsString('MP4audio');
      final outputPath = '${directory.path}/native_saf_work_123.flac';
      final result = DownloadResult.fromMap({
        'file_name': 'Artist - Song.m4a',
        'file_path': source.path,
        'output_extension': '.m4a',
        'saf_deferred_publish': true,
      });
      final path = await finalize(
        finalizer(probe: (_) async => 'flac', convert: (_) async => outputPath),
        result,
        path: source.path,
        saf: true,
      );
      expect(path, outputPath);
      expect(result.filePath, outputPath);
      expect(result.fileName, 'Artist - Song.flac');
      expect(result.outputExtension(), '.flac');
    },
  );

  test(
    'SAF publication adopts FLAC name only after tags and successful write',
    () async {
      for (final published in [false, true]) {
        final temp = File('${directory.path}/temporary.m4a');
        var deleted = false;
        final replacer = DownloadSafFileReplacer(
          copyToTemp: (_) async => (await temp.writeAsString('fLaCaudio')).path,
          publish:
              ({
                required treeUri,
                required relativeDir,
                required fileName,
                required srcPath,
                required avoidOverwrite,
                required preservedSuffix,
                collisionCleanFileName,
                collisionVariantFileName,
              }) async {
                expect(fileName, 'Song.flac');
                expect(relativeDir, 'Artist/Album');
                expect(await File(srcPath).readAsString(), 'fLaCtagged');
                return published
                    ? (uri: 'content://final', fileName: fileName)
                    : null;
              },
          deleteSource: (_) async => deleted = true,
        );
        final result = DownloadResult.fromMap({
          'file_name': 'Song.m4a',
          'audio_codec': 'm4a',
          'decryption_key': 'abcd',
          'output_extension': '.mp4',
        });
        final stage = finalizer(
          probe: (_) async => 'flac',
          replaceSaf: replacer.replace,
        );
        final path = await finalize(
          stage,
          result,
          path: 'content://original',
          saf: true,
          embed: (path) async => File(path).writeAsString('fLaCtagged'),
        );
        expect(path, published ? 'content://final' : null);
        expect(result.fileName, published ? 'Song.flac' : 'Song.m4a');
        expect(result.audioCodec, published ? 'flac' : 'm4a');
        expect(result.filePath, published ? 'content://final' : null);
        expect(deleted, published);
        expect(await directory.list().length, 0);
      }
    },
  );

  test(
    'failed conversion and required tag failure never mark output as FLAC',
    () async {
      final result = DownloadResult.fromMap({'audio_codec': 'alac'});
      final failed = finalizer(
        probe: (_) async => 'alac',
        convert: (_) async => null,
      );
      expect(await finalize(failed, result), isNull);
      expect(result.audioCodec, 'alac');
      final tagFailure = finalizer(
        probe: (_) async => 'alac',
        convert: (_) async => '/Song.flac',
      );
      await expectLater(
        finalize(
          tagFailure,
          result,
          embed: (_) async => throw StateError('Tag failure'),
        ),
        throwsStateError,
      );
      expect(result.audioCodec, 'alac');
    },
  );
}
