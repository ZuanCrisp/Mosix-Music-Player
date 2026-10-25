import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/file_access_check.dart';
import 'package:mornye/utils/file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('local stat OS boundary', () {
    late Directory temporary;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('file_stat_boundary_');
    });
    tearDown(() async {
      await temporary.delete(recursive: true);
    });

    test('found and CUE backing files retain actual stat metadata', () async {
      final file = await File(
        '${temporary.path}/album.cue',
      ).writeAsString('CUE fixture');
      final expected = await file.stat();
      final result = await fileStat('${file.path}#track01');
      expect(result?.size, expected.size);
      expect(result?.modified, expected.modified);
    });

    test('ENOENT and ENOTDIR are confirmed missing', () async {
      final file = await File(
        '${temporary.path}/track.flac',
      ).writeAsString('audio');
      for (final path in [
        '${temporary.path}/removed.flac',
        '${file.path}/child.flac',
      ]) {
        expect(await checkFileAccess(path), isA<FileAccessMissing>());
      }
    });

    test('symlink loop is unavailable instead of deleted', () async {
      final path = '${temporary.path}/loop.flac';
      await Link(path).create(path);
      expect((await FileStat.stat(path)).type, FileSystemEntityType.notFound);
      final result = await checkFileAccess(path);
      expect(result, isA<FileAccessUnavailable>());
      expect(
        (result as FileAccessUnavailable).error,
        isA<FileSystemException>(),
      );
    }, skip: Platform.isWindows);

    test('permission denied is unavailable instead of deleted', () async {
      final directory = await Directory(
        '${temporary.path}/restricted',
      ).create();
      final file = await File(
        '${directory.path}/track.flac',
      ).writeAsString('audio');
      final chmod = await Process.run('chmod', ['000', directory.path]);
      expect(chmod.exitCode, 0);
      try {
        expect(
          (await FileStat.stat(file.path)).type,
          FileSystemEntityType.notFound,
          reason: 'The OS fixture must actually deny directory traversal',
        );
        final result = await checkFileAccess(file.path);
        expect(result, isA<FileAccessUnavailable>());
        final error = (result as FileAccessUnavailable).error;
        expect(error, isA<FileSystemException>());
        expect((error as FileSystemException).osError?.errorCode, 13);
      } finally {
        await Process.run('chmod', ['700', directory.path]);
      }
    }, skip: Platform.isWindows);
  });

  test(
    'network identity and empty paths avoid filesystem/provider calls',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        fail('Network identities must not query SAF');
      });
      expect(await fileStat(null), isNull);
      expect(await fileStat(''), isNull);
      final result = await fileStat('network://provider/track');
      expect(result, isA<FileAccessStat>());
      expect(result?.size, isNull);
      expect(result?.modified, isNull);
    },
  );

  test('SAF CUE stat queries once and preserves nullable metadata', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return '{"exists":true,"size":null,"modified":null,"mime_type":null}';
    });
    const uri = 'content://example.documents/tree/root/document/album%2Fcue';
    final result = await checkFileAccess('$uri#track02');
    expect(result, isA<FileAccessFound>());
    expect((result as FileAccessFound).stat.size, isNull);
    expect(result.stat.modified, isNull);
    expect(calls.map((call) => call.method), ['safStat']);
    expect(calls.single.arguments, {'uri': uri});
  });

  test('SAF confirmed absence is missing', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return '{"exists":false,"size":null,"modified":null}';
    });
    expect(
      await checkFileAccess('content://example.documents/document/removed'),
      isA<FileAccessMissing>(),
    );
  });

  for (final code in ['permission_denied', 'provider_unavailable']) {
    test(
      'SAF $code reaches the unavailable state through the bridge',
      () async {
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          throw PlatformException(code: code, message: 'Native query failed');
        });
        final result = await checkFileAccess(
          'content://example.documents/document/track.flac',
        );
        expect(result, isA<FileAccessUnavailable>());
        final error = (result as FileAccessUnavailable).error;
        expect(error, isA<PlatformException>());
        expect((error as PlatformException).code, code);
        expect(calls, ['safStat']);
      },
    );
  }
}
