import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/utils/path_match_keys.dart';

void main() {
  test(
    'native library fixtures preserve production Dart row and path codecs',
    () {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/native_library_contract.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final entry in fixture['rows'] as List) {
        final value = entry as Map<String, dynamic>;
        expect(
          LibraryRowMapper.encode(
            Map<String, dynamic>.from(value['input'] as Map),
            sourceId: 'source',
          ),
          value['expected'],
        );
      }
      for (final entry in fixture['paths'] as List) {
        final value = entry as Map<String, dynamic>;
        expect(
          buildPathMatchKeys(value['input'] as String).toList()..sort(),
          value['expected'],
          reason: value['input'] as String,
        );
      }
    },
  );
}
