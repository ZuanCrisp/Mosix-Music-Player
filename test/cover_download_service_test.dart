import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/cover_download_service.dart';

void main() {
  test('detects common cover formats from file headers', () async {
    final directory = await Directory.systemTemp.createTemp('cover_format_');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final png = File(
      '${directory.path}/png',
    )..writeAsBytesSync(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    final webp = File('${directory.path}/webp')
      ..writeAsBytesSync(const [
        0x52,
        0x49,
        0x46,
        0x46,
        0,
        0,
        0,
        0,
        0x57,
        0x45,
        0x42,
        0x50,
      ]);
    final jpeg = File('${directory.path}/jpeg')
      ..writeAsBytesSync(const [0xff, 0xd8, 0xff, 0xe0]);

    expect(await CoverDownloadService.detectCoverFileFormat(png), (
      extension: 'png',
      mimeType: 'image/png',
    ));
    expect(await CoverDownloadService.detectCoverFileFormat(webp), (
      extension: 'webp',
      mimeType: 'image/webp',
    ));
    expect(await CoverDownloadService.detectCoverFileFormat(jpeg), (
      extension: 'jpg',
      mimeType: 'image/jpeg',
    ));
  });

  test('builds a collision-free file path', () async {
    final directory = await Directory.systemTemp.createTemp('cover_name_');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    File('${directory.path}/Album_cover.jpg').writeAsStringSync('one');
    File('${directory.path}/Album_cover (2).jpg').writeAsStringSync('two');

    final result = await CoverDownloadService.uniqueFilePath(
      directory.path,
      'Album_cover.jpg',
    );

    expect(result, endsWith('Album_cover (3).jpg'));
  });
}
