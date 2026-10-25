import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_scan_failure.dart';
import 'package:mornye/utils/local_library_scan_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('names a document from its URI and a file from its path', () {
    const document = LibraryScanFailure(
      path:
          'content://example.documents/tree/primary%3AMusic/document/'
          'primary%3AMusic%2FAlbum%2FSong%20One.flac',
      message: 'EIO',
    );
    expect(document.fileName, 'Song One.flac');
    expect(document.folder, 'Music/Album');

    const topLevel = LibraryScanFailure(
      path: 'content://example.documents/document/1234%3ASong.opus',
      message: 'EIO',
    );
    expect(topLevel.fileName, 'Song.opus');
    expect(topLevel.folder, isEmpty);

    const file = LibraryScanFailure(
      path: r'C:\Music\Album\Song.mp3',
      message: 'EIO',
    );
    expect(file.fileName, 'Song.mp3');
    expect(file.folder, 'C:/Music/Album');

    const malformed = LibraryScanFailure(
      path: 'content://example.documents/document/%E0%A4%A.flac',
      message: 'EIO',
    );
    expect(malformed.fileName, isNotEmpty);
  });

  test('reads a finished progress report and ignores malformed rows', () {
    final failures = LibraryScanFailures.fromProgress({
      'error_count': 3,
      'failures': [
        {'path': '/music/a.flac', 'message': 'invalid FLAC header'},
        'not a row',
        {'path': '/music/b.mp3'},
      ],
    });
    expect(failures.count, 3);
    expect(failures.files.map((file) => file.path), [
      '/music/a.flac',
      '/music/b.mp3',
    ]);
    expect(failures.files.last.message, isEmpty);
  });

  test('stored failures survive a round trip and tolerate bad data', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await writeLocalLibraryScanFailures(prefs, {
      'source': const LibraryScanFailures(
        count: 120,
        files: [LibraryScanFailure(path: '/music/a.flac', message: 'EIO')],
      ),
    });
    final read = readLocalLibraryScanFailures(prefs)['source']!;
    expect(read.count, 120);
    expect(read.files.single.path, '/music/a.flac');
    expect(read.files.single.message, 'EIO');

    await writeLocalLibraryScanFailures(prefs, const {});
    expect(prefs.containsKey(localLibraryScanFailuresKey), isFalse);

    await prefs.setString(localLibraryScanFailuresKey, '{not json');
    expect(readLocalLibraryScanFailures(prefs), isEmpty);
    await prefs.setString(localLibraryScanFailuresKey, '[1, 2]');
    expect(readLocalLibraryScanFailures(prefs), isEmpty);
  });
}
