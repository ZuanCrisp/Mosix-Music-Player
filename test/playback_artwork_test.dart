import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/utils/playback_artwork.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('restored-artwork-');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'SAF artwork recovers from missing scan covers and tolerates provider errors',
    () async {
      const source = 'content://example.documents/nas/song.flac';
      final cover = File('${directory.path}/recovered #1.jpg');
      await cover.writeAsBytes([1]);
      for (final missing in [null, '${directory.path}/removed.jpg']) {
        expect(
          await resolveMissingDocumentArtworkUri(
            source,
            missing,
            extract: (path) async {
              expect(path, source);
              return cover.path;
            },
          ),
          cover.uri.toString(),
        );
      }
      var unnecessaryReads = 0;
      Future<String?> unexpectedRead(String _) async {
        unnecessaryReads++;
        return null;
      }

      for (final existing in [
        cover.path,
        cover.uri.toString(),
        'https://example.test/cover.jpg',
      ]) {
        expect(
          await resolveMissingDocumentArtworkUri(
            source,
            existing,
            extract: unexpectedRead,
          ),
          isNull,
        );
      }
      expect(
        await resolveMissingDocumentArtworkUri(
          source,
          null,
          extract: (_) async => throw const SocketException('NAS offline'),
        ),
        isNull,
      );
      expect(
        await resolveMissingDocumentArtworkUri(
          '/local/song.flac',
          null,
          extract: unexpectedRead,
        ),
        isNull,
      );
      expect(unnecessaryReads, 0);
    },
  );

  test(
    'restored queue replaces a removed scan cover with current Library art',
    () async {
      final removed = File(
        '${directory.path}/old-scan/cover.jpg',
      ).uri.toString();
      final current = File('${directory.path}/current cover #1.jpg');
      await current.writeAsBytes([1]);
      final resolved = await resolveRestoredArtworkUri(
        removed,
        loadLibraryCoverPath: () async => current.path,
      );
      expect(resolved, current.uri.toString());
      expect(File(Uri.parse(resolved!).toFilePath()).existsSync(), isTrue);
    },
  );

  test(
    'valid local and remote covers do not trigger Library lookups',
    () async {
      final current = File('${directory.path}/cover.jpg');
      await current.writeAsBytes([1]);
      for (final artwork in [
        current.path,
        current.uri.toString(),
        'https://example.com/cover.jpg',
      ]) {
        var lookups = 0;
        final resolved = await resolveRestoredArtworkUri(
          artwork,
          loadLibraryCoverPath: () async {
            lookups++;
            return null;
          },
        );
        expect(resolved, artwork);
        expect(lookups, 0);
      }
    },
  );

  test(
    'a missing Library image or lookup failure leaves the session usable',
    () async {
      final missing = File('${directory.path}/missing.jpg').uri.toString();
      expect(
        await resolveRestoredArtworkUri(
          missing,
          loadLibraryCoverPath: () async =>
              '${directory.path}/also-missing.jpg',
        ),
        missing,
      );
      expect(
        await resolveRestoredArtworkUri(
          missing,
          loadLibraryCoverPath: () async =>
              throw StateError('Library unavailable'),
        ),
        missing,
      );
    },
  );
}
