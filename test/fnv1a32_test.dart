import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/hash_utils.dart';

String _hex(int hash) => hash.toRadixString(16).padLeft(8, '0');

void main() {
  // Expected values were computed from the original inline implementations
  // (scan output name over UTF-8 bytes, staging label over UTF-16 units).
  test('fnv1a32 over UTF-8 bytes matches the scan output name hash', () {
    expect(_hex(fnv1a32(utf8.encode(''))), '811c9dc5');
    expect(_hex(fnv1a32(utf8.encode('track-123'))), '8277aead');
    expect(
      _hex(
        fnv1a32(
          utf8.encode('{"method":"scan","arguments":{"path":"content://x/y"}}'),
        ),
      ),
      '94bc90df',
    );
    expect(_hex(fnv1a32(utf8.encode('café 日本'))), 'c843754b');
  });

  test('qualityVariantStagingLabel matches the original code units hash', () {
    expect(qualityVariantStagingLabel(''), 'qv_811c9dc5');
    expect(qualityVariantStagingLabel('a'), 'qv_e40c292c');
    expect(qualityVariantStagingLabel('track-123'), 'qv_8277aead');
    expect(qualityVariantStagingLabel('café 日本'), 'qv_73a64e9d');
  });
}
