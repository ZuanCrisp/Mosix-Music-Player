import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/metadata_cover_resources.dart';

void main() {
  test(
    'closing an editor preserves artwork until its save lease finishes',
    () async {
      final resources = MetadataCoverResources();
      final preview = await resources.copyPicked(
        extension: 'png',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final release = resources.retain();
      await resources.dispose();
      expect(await File(preview.path).readAsBytes(), [1, 2, 3]);
      await release();
      expect(await Directory(preview.tempDir).exists(), isFalse);
      await release();
    },
  );

  test(
    'disposal during a file creation cleans the completed resource',
    () async {
      final resources = MetadataCoverResources();
      final pending = resources.copyPicked(
        extension: 'jpg',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      await resources.dispose();
      final preview = await pending;
      expect(await Directory(preview.tempDir).exists(), isFalse);
    },
  );

  test(
    'replacing artwork defers release until every save lease finishes',
    () async {
      final resources = MetadataCoverResources();
      addTearDown(resources.dispose);
      final preview = await resources.copyPicked(
        extension: 'png',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final firstSave = resources.retain();
      final secondSave = resources.retain();
      await resources.release(preview.tempDir);
      expect(await File(preview.path).readAsBytes(), [1, 2, 3]);
      await firstSave();
      expect(await File(preview.path).exists(), isTrue);
      await secondSave();
      expect(await Directory(preview.tempDir).exists(), isFalse);
    },
  );

  test(
    'releasing a selected image leaves other editor resources intact',
    () async {
      final resources = MetadataCoverResources();
      addTearDown(resources.dispose);
      final first = await resources.copyPicked(
        extension: 'png',
        bytes: Uint8List.fromList([1]),
      );
      final second = await resources.copyPicked(
        extension: 'jpg',
        bytes: Uint8List.fromList([2]),
      );
      await resources.release(first.tempDir);
      expect(await Directory(first.tempDir).exists(), isFalse);
      expect(await File(second.path).exists(), isTrue);
    },
  );
}
