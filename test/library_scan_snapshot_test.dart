import 'dart:io';
import 'package:flutter/services.dart';
import 'package:mosix/services/library_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'scan snapshot preserves normalized sentinel and backfilled timestamps across chunks',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'scan-snapshot-test-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      });
      final timestamps = <String, int>{
        for (var i = 0; i < 4000; i++) '/music/歌曲 café $i.flac': i,
        '/music/legacy.flac': -1,
        '/music/backfilled.flac': 1720000000000,
      };
      final path = await LibraryDatabase.instance.writeFileModTimesSnapshot(
        timestamps,
      );
      final lines = await File(path).readAsLines();
      expect(
        lines,
        timestamps.entries
            .map((entry) => '${entry.value}\t${entry.key}')
            .toList(),
      );
    },
  );
}
