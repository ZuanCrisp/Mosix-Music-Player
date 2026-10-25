import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('splits folder separators without splitting date format tokens', () {
    expect(
      FolderPathTemplate.segments(r'{artist}\{date:%Y/%m}/Disc {disc:02}'),
      ['{artist}', '{date:%Y/%m}', 'Disc {disc:02}'],
    );
  });

  test('rejects absolute, traversal, empty and malformed templates', () {
    for (final template in [
      '',
      '/Music/{album}',
      r'C:\Music',
      r'\\server\share',
      '../{album}',
      '{artist}/../{album}',
      './{album}',
      '{artist}//{album}',
      '{album}/',
      '{unknown}',
      '{album',
      'album}',
      '{{album}}',
      '{track:999999}',
      'Music\n{album}',
    ]) {
      expect(FolderPathTemplate.isValid(template), isFalse, reason: template);
    }
    for (final template in [
      ...FolderPathTemplate.basicTags,
      ...FolderPathTemplate.advancedTags,
    ]) {
      expect(FolderPathTemplate.isValid(template), isTrue, reason: template);
    }
  });

  test(
    'metadata cannot introduce folders, traversal or Windows device names',
    () async {
      final outputs = {
        '{artist}': '../AC/DC',
        '{album}': 'CON.txt',
        '{title}': r'..\hidden:*?',
      };
      final path = await FolderPathTemplate.expand(
        '{artist}/{album}/{title}',
        const {},
        buildFilename: (template, metadata) async => outputs[template]!,
      );
      expect(path, 'AC DC/_CON.txt/hidden');
      expect(path.split('/'), hasLength(3));
    },
  );

  test(
    'folder-specific tags and empty metadata produce portable components',
    () async {
      expect(
        await FolderPathTemplate.expand(
          '{album_artist}/{playlist}/{year}',
          {'album_artist': 'One / Two', 'playlist': 'Road: Trip'},
          buildFilename: (template, metadata) async =>
              template == '{year}' ? '' : template,
        ),
        'One Two/Road Trip/Unknown',
      );
      expect(FolderPathTemplate.sanitizeComponent(' aux. '), '_aux');
      expect(FolderPathTemplate.sanitizeComponent('LPT1'), '_LPT1');
      expect(FolderPathTemplate.sanitizeComponent('...'), 'Unknown');
      final long = FolderPathTemplate.sanitizeComponent('音' * 100);
      expect(utf8.encode(long).length, 120);
      expect(long, '音' * 40);
    },
  );

  test('invalid template is rejected before invoking the backend', () async {
    var calls = 0;
    await expectLater(
      FolderPathTemplate.expand(
        '../{album}',
        const {},
        buildFilename: (_, _) async {
          calls++;
          return '';
        },
      ),
      throwsFormatException,
    );
    expect(calls, 0);
  });

  test(
    'desktop native formatter expands date and numeric tags in folders',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'folder-template-native-',
      );
      addTearDown(() => directory.delete(recursive: true));
      debugDesktopPlatformOverride = true;
      RustFfiBackend.debugShared = RustFfiBackend(
        loadConfig: () async => DesktopBackendConfig(
          appSupportDir: directory.path,
          documentsDir: directory.path,
          tempDir: directory.path,
        ),
      );
      addTearDown(() {
        debugDesktopPlatformOverride = null;
        RustFfiBackend.debugShared = null;
      });
      expect(
        await FolderPathTemplate.expand(
          r'{artist}\{date:%Y-%m-%d} - {album}/Disc {disc:02}',
          {
            'artist': 'AC/DC',
            'album': 'Example: Album',
            'date': '2026-05-04',
            'disc': 2,
          },
        ),
        'AC DC/2026-05-04 - Example Album/Disc 02',
      );
    },
    skip: Platform.environment['MORNYE_DESKTOP_LIB'] == null,
  );
}
