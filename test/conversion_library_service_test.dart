import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/conversion_library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'SAF conversion removes _converted and retries a transient write',
    () async {
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'safCreateUniqueFromPath');
            expect((call.arguments as Map)['file_name'], 'Song.mp3');
            attempts++;
            if (attempts == 1) {
              throw PlatformException(code: 'temporary_io');
            }
            return jsonEncode({
              'uri': 'content://music/Song%20(2).mp3',
              'file_name': 'Song (2).mp3',
            });
          });

      final published = await ConversionLibraryService.publishSafConversion(
        treeUri: 'content://music/tree/root',
        relativeDir: 'Album',
        originalFileName: 'Song.flac',
        targetFormat: 'mp3',
        sourcePath: '/tmp/Song.mp3',
        keepOriginal: true,
      );

      expect(attempts, 2);
      expect(published?.fileName, 'Song (2).mp3');
    },
  );

  test(
    'same-format replacement reuses the original SAF document name',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'safCreateFromPath');
            expect((call.arguments as Map)['file_name'], 'Song.flac');
            return 'content://music/Song.flac';
          });

      final published = await ConversionLibraryService.publishSafConversion(
        treeUri: 'content://music/tree/root',
        relativeDir: 'Album',
        originalFileName: 'Song.flac',
        targetFormat: 'flac',
        sourcePath: '/tmp/Song.flac',
        keepOriginal: false,
      );

      expect(published?.fileName, 'Song.flac');
    },
  );
}
