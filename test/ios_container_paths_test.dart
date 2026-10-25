import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/ios_container_paths.dart';

void main() {
  group('rebaseIosSandboxPath', () {
    const oldContainer =
        '/var/mobile/Containers/Data/Application/'
        '11111111-1111-4111-8111-111111111111';
    const newDocuments =
        '/var/mobile/Containers/Data/Application/'
        '22222222-2222-4222-8222-222222222222/Documents';
    const newContainer =
        '/var/mobile/Containers/Data/Application/'
        '22222222-2222-4222-8222-222222222222';

    test('rebases supported device roots and preserves suffixes', () {
      for (final root in const [
        'Documents',
        'Library/Application Support',
        'Library/Caches',
      ]) {
        for (final suffix in const [
          '',
          '/Music/曲 name #track01.flac',
          '/Music/曲 name.flac#track01',
        ]) {
          final oldPath = '$oldContainer/$root$suffix';
          expect(
            rebaseIosSandboxPath(oldPath, newDocuments),
            '$newContainer/$root$suffix',
          );
        }
      }
      const privatePath =
          '/private/var/mobile/Containers/Data/Application/'
          '11111111-1111-4111-8111-111111111111/Documents/曲.flac';
      expect(
        rebaseIosSandboxPath(privatePath, newDocuments),
        '$newContainer/Documents/曲.flac',
      );
    });

    test('rebases simulator containers', () {
      const oldPath =
          '/Users/test/Library/Developer/CoreSimulator/Devices/'
          '33333333-3333-4333-8333-333333333333/data/Containers/Data/'
          'Application/55555555-5555-4555-8555-555555555555/'
          'Documents/音楽 folder/song #track01.m4a';
      const newDocuments =
          '/Users/test/Library/Developer/CoreSimulator/Devices/'
          '44444444-4444-4444-8444-444444444444/data/Containers/Data/'
          'Application/66666666-6666-4666-8666-666666666666/'
          'Documents';
      final newContainer = newDocuments.substring(
        0,
        newDocuments.length - '/Documents'.length,
      );
      expect(
        rebaseIosSandboxPath(oldPath, newDocuments),
        '$newContainer/Documents/音楽 folder/song #track01.m4a',
      );
    });

    test('is idempotent for the current container', () {
      const currentPath =
          '$newContainer/Documents/音楽 folder/song #track01.flac';
      expect(rebaseIosSandboxPath(currentPath, newDocuments), currentPath);
    });

    test('leaves roots, traversal, URIs, and external paths unchanged', () {
      const unchanged = [
        oldContainer,
        '$oldContainer/',
        '$oldContainer/tmp/song.flac',
        '$oldContainer/Documents/../Library/Caches/cover.jpg',
        '$oldContainer/Documents-extra/song.flac',
        '/outside$oldContainer/Documents/song.flac',
        '/tmp/song.flac',
        'content://downloads/song.flac',
        'file:///var/mobile/Containers/Data/Application/OLD/song.flac',
        '/data/user/0/com.example/files/song.flac',
        '/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/song.flac',
        'Documents/song.flac',
      ];
      for (final path in unchanged) {
        expect(rebaseIosSandboxPath(path, newDocuments), path);
      }
    });

    test('requires a current iOS Documents directory', () {
      const oldPath = '$oldContainer/Documents/song.flac';
      for (final documents in const [
        '',
        '/Documents',
        '/data/user/0/com.example/files/Documents',
        '$newContainer/Documents/subfolder',
        '$newContainer/Library/Application Support',
      ]) {
        expect(rebaseIosSandboxPath(oldPath, documents), oldPath);
      }
    });
  });
}
