// Host-only injection of the same libsmb2 release shipped by the plugin.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:io';

// ignore: implementation_imports
import 'package:dart_smb2/src/ffi/native_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/services/network_storage_service.dart';

void main() {
  test(
    'SMB uploads, reconciles retries and deletes only the selected file',
    () async {
      debugLibSmb2PathOverride = Platform.environment['TEST_SMB_LIBRARY'];
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      final temp = await Directory.systemTemp.createTemp('smb-upload-');
      addTearDown(() async {
        await storage.dispose();
        await temp.delete(recursive: true);
        debugLibSmb2PathOverride = null;
      });
      final c = NetworkConnection(
        id: 'nas',
        name: 'Test NAS',
        protocol: NetworkProtocol.smb,
        address:
            'smb://127.0.0.1:${Platform.environment['TEST_SMB_PORT'] ?? '1446'}/MUSIC/',
        username: 'test',
        password: 'secret',
      );
      await storage.save(c);
      final audio = await File(
        '${temp.path}/song.flac',
      ).writeAsBytes(List.generate(700000, (i) => i % 251));
      await storage.checkUploadAccess('network://nas/');
      final name = 'Song #${NetworkStorageService.newId()}.flac';
      final target = await storage.prepareUpload(
        'network://nas/',
        'Uploads/Album/',
        name,
      );
      var lastProgress = 0;
      await storage.publishUpload(
        target,
        audio,
        'smb-test',
        checkpoint: () {},
        progress: (sent, total) {
          expect(sent, greaterThanOrEqualTo(lastProgress));
          expect(sent, lessThanOrEqualTo(total));
          lastProgress = sent;
        },
      );
      expect(lastProgress, await audio.length());
      // Existing identical content is adopted without overwriting the file.
      await storage.publishUpload(
        target,
        audio,
        'smb-test',
        checkpoint: () {},
        progress: (_, _) {},
      );
      final uri = Uri.parse(target);
      final parent = uri.pathSegments
          .take(uri.pathSegments.length - 1)
          .join('/');
      final entries = await storage.list(c, '$parent/');
      expect(entries.map((e) => e.name).toList(), [name]);
      expect(entries.single.size, await audio.length());
      final collision = await storage.prepareUpload(
        'network://nas/',
        '$parent/',
        name,
      );
      expect(
        Uri.parse(collision).pathSegments.last,
        name.replaceFirst('.flac', ' (2).flac'),
      );
      // A path without a trailing slash still must not delete a directory.
      expect(await storage.deleteFile('network://nas/$parent'), isFalse);
      expect(await storage.deleteFile(target), isTrue);
      expect(await storage.list(c, '$parent/'), isEmpty);
      expect(await storage.deleteFile(target), isTrue);
    },
    skip: Platform.environment['TEST_SMB_UPLOAD'] != '1',
  );
}
