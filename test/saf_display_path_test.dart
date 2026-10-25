import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/saf_display_path.dart';

void main() {
  group('SAF document locations', () {
    test('keeps Unicode and reserved filename characters decoded once', () {
      final uri = Uri(
        scheme: 'content',
        host: 'com.android.externalstorage.documents',
        pathSegments: const [
          'tree',
          'primary:Music',
          'document',
          'primary:Music/Like a Prayer (From “Deadpool & Wolverine”).alac',
        ],
      ).toString();

      final location = resolveSafDocumentLocation(uri);

      expect(location, isNotNull);
      expect(
        location!.treeUri,
        'content://com.android.externalstorage.documents/tree/primary%3AMusic',
      );
      expect(location.relativeDir, isEmpty);
      expect(
        location.fileName,
        'Like a Prayer (From “Deadpool & Wolverine”).alac',
      );
    });

    test('preserves Unicode folders, emoji, and a literal percent sign', () {
      final uri = Uri(
        scheme: 'content',
        host: 'com.android.externalstorage.documents',
        pathSegments: const [
          'tree',
          'primary:Music/Beyoncé',
          'document',
          'primary:Music/Beyoncé/日本語/100% & 🎵.flac',
        ],
      ).toString();

      final location = resolveSafDocumentLocation(uri);

      expect(location, isNotNull);
      expect(
        location!.treeUri,
        'content://com.android.externalstorage.documents/tree/'
        'primary%3AMusic%2FBeyonc%C3%A9',
      );
      expect(location.relativeDir, '日本語');
      expect(location.fileName, '100% & 🎵.flac');
    });

    test('rejects a document URI without writable tree context', () {
      expect(
        resolveSafDocumentLocation(
          'content://com.android.providers.media.documents/'
          'document/audio%3A12345',
        ),
        isNull,
      );
    });
  });

  group('SAF display paths', () {
    test('normalizes an external-storage document URI', () {
      const uri =
          'content://com.android.externalstorage.documents/'
          'document/primary%3AMusic%2FMornye%2FSong.flac';

      expect(
        formatSafUriForDisplay(uri),
        '/storage/emulated/0/Music/Mornye/Song.flac',
      );
    });

    test('rebuilds a friendly path for an opaque SAF document ID', () {
      expect(
        buildSafFileDisplayPath(
          pathOrUri:
              'content://com.android.providers.media.documents/'
              'document/audio%3A1000192991',
          treeUri:
              'content://com.android.externalstorage.documents/'
              'tree/primary%3AMusic%2FMornye',
          treeDisplayPath: '/storage/emulated/0/Music/Mornye',
          relativeDir: 'Falling In Reverse/Popular Monster',
          fileName: '01 - Popular Monster.flac',
        ),
        '/storage/emulated/0/Music/Mornye/'
        'Falling In Reverse/Popular Monster/01 - Popular Monster.flac',
      );
    });

    test('does not present a MediaStore ID as an SD-card path', () {
      const uri =
          'content://com.android.providers.media.documents/'
          'document/audio%3A12345';
      expect(formatSafUriForDisplay(uri), uri);
    });

    test('keeps ordinary filesystem paths unchanged', () {
      const path = '/storage/emulated/0/Music/Song.flac';
      expect(formatSafUriForDisplay(path), path);
      expect(buildSafFileDisplayPath(pathOrUri: path), path);
    });
  });
}
