import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/download_saf_file_replacer.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('saf-replacement-');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'failed transforms and publications preserve the source and clean every temp',
    () async {
      for (final failure in [
        'transform-null',
        'transform-throw',
        'publish-null',
        'publish-throw',
      ]) {
        final temp = File('${directory.path}/input.flac');
        final output = File('${directory.path}/output.flac');
        final replacer = DownloadSafFileReplacer(
          copyToTemp: (_) async => (await temp.writeAsString('source')).path,
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
                expect(failure, startsWith('publish'));
                if (failure == 'publish-throw') {
                  throw StateError('Publishing failed');
                }
                return null;
              },
          deleteSource: (_) async => fail('Deleted source before publication'),
        );
        final operation = replacer.replace(
          uri: 'content://original',
          treeUri: 'content://tree',
          relativeDir: 'Album',
          op: (path, addCleanup) async {
            expect(await File(path).readAsString(), 'source');
            await output.writeAsString('transformed');
            addCleanup(output.path);
            if (failure == 'transform-null') return null;
            if (failure == 'transform-throw') {
              throw StateError('Transform failed');
            }
            return (output.path, 'Song.flac');
          },
        );
        if (failure.endsWith('throw')) {
          await expectLater(operation, throwsStateError);
        } else {
          expect(await operation, isNull);
        }
        expect(await directory.list().length, 0, reason: failure);
      }
    },
  );

  test(
    'unregistered output is cleaned and same-URI publication keeps the source',
    () async {
      final temp = File('${directory.path}/input.flac');
      final output = File('${directory.path}/output.flac');
      String? publishedName;
      final replacer = DownloadSafFileReplacer(
        copyToTemp: (_) async => (await temp.writeAsString('source')).path,
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
              expect(treeUri, 'content://tree');
              expect(relativeDir, 'Artist/Album');
              expect(await File(srcPath).readAsString(), 'transformed');
              expect(collisionCleanFileName, 'Song.flac');
              expect(collisionVariantFileName, 'Song - 24bit-96kHz.flac');
              expect(preservedSuffix, '24bit-96kHz');
              return (uri: 'content://original', fileName: 'Song (2).flac');
            },
        deleteSource: (_) async => fail('Deleted the published URI'),
      );
      expect(
        await replacer.replace(
          uri: 'content://original',
          treeUri: 'content://tree',
          relativeDir: 'Artist/Album',
          preservedSuffix: '24bit-96kHz',
          collisionCleanFileName: 'Song.flac',
          collisionVariantFileName: 'Song - 24bit-96kHz.flac',
          onPublishedFileName: (name) => publishedName = name,
          op: (_, _) async =>
              ((await output.writeAsString('transformed')).path, 'Song.flac'),
        ),
        'content://original',
      );
      expect(publishedName, 'Song (2).flac');
      expect(await directory.list().length, 0);
    },
  );

  test(
    'inaccessible source never starts a transformation or publication',
    () async {
      final replacer = DownloadSafFileReplacer(
        copyToTemp: (_) async => null,
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
            }) async => throw StateError('Unexpected publication'),
        deleteSource: (_) async => fail('Unexpected source deletion'),
      );
      expect(
        await replacer.replace(
          uri: 'content://original',
          treeUri: 'content://tree',
          relativeDir: '',
          op: (_, _) async => throw StateError('Unexpected transform'),
        ),
        isNull,
      );
    },
  );
}
