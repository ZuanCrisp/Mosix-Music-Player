import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'native replacement is exposed to the download queue as file_path',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'runPostProcessingV2');
            expect(call.arguments, {
              'input': jsonEncode({
                'item_id': 'queue-item',
                'path': '/music/original.flac',
              }),
              'metadata': jsonEncode({'title': 'Example'}),
            });
            return jsonEncode({
              'success': true,
              'new_file_path': '/music/converted.m4a',
            });
          });
      final result = await PlatformBridge.runPostProcessingV2(
        '/music/original.flac',
        metadata: {'title': 'Example'},
        itemId: 'queue-item',
      );
      expect(result['file_path'], '/music/converted.m4a');
      expect(result['new_file_path'], '/music/converted.m4a');
    },
  );

  test(
    'SAF keeps the destination URI instead of exposing a staging path',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.arguments, {
              'input': jsonEncode({'uri': 'content://example/document/track'}),
              'metadata': '',
            });
            return jsonEncode({
              'success': true,
              'new_file_path': '/cache/processed.flac',
              'new_file_uri': 'content://example/document/track',
            });
          });
      final result = await PlatformBridge.runPostProcessingV2(
        'content://example/document/track',
      );
      expect(result['file_path'], 'content://example/document/track');
    },
  );

  test(
    'legacy results, no-op hooks and failures retain their contracts',
    () async {
      for (final response in <Map<String, dynamic>>[
        {'success': true, 'file_path': '/music/legacy.flac'},
        {'success': true, 'new_file_path': ''},
        {'success': false, 'error': 'processing failed'},
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (_) async => jsonEncode(response),
            );
        final result = await PlatformBridge.runPostProcessingV2(
          '/music/original.flac',
        );
        if (response['success'] == true) {
          expect(
            result['file_path'],
            response['file_path'] ?? '/music/original.flac',
          );
        } else {
          expect(result, response);
        }
      }
    },
  );
}
