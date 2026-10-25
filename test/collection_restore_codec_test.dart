import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/collection_restore_codec.dart';

void main() {
  test(
    'worker and streamed commands preserve the existing collection codec',
    () async {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/collection_restore_contract.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final input = fixture['input'] as Map<String, dynamic>;
      final now = fixture['now'] as String;
      expect(
        collectionRestoreCommands(input, now).toList(),
        fixture['commands'],
      );
      expect(
        await prepareCollectionRestoreCommands(input, now),
        fixture['commands'],
      );
      final temporary = await Directory.systemTemp.createTemp(
        'collection-codec-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final path = '${temporary.path}/commands.ndjson';
      expect(await writeCollectionRestoreCommands(path, input, now), 9);
      expect(
        (await File(path).readAsLines()).map(jsonDecode).toList(),
        fixture['commands'],
      );
    },
  );

  test('empty or omitted categories produce an empty replacement', () async {
    expect(await prepareCollectionRestoreCommands({}, 'now'), isEmpty);
    expect(
      await prepareCollectionRestoreCommands({
        'wishlist': false,
        'loved': <String, dynamic>{},
        'playlists': [
          null,
          {'id': ''},
        ],
        'favoriteArtists': [
          {'key': ''},
        ],
      }, 'now'),
      isEmpty,
    );
  });

  test(
    'invalid typed fields still reject the restore before publication',
    () async {
      for (final input in <Map<String, dynamic>>[
        {
          'wishlist': [
            {'key': 7, 'track': <String, dynamic>{}},
          ],
        },
        {
          'playlists': [
            {'id': 'p', 'coverImagePath': false},
          ],
        },
        {
          'favoriteArtists': [
            {'key': 'a', 'addedAt': 1},
          ],
        },
      ]) {
        await expectLater(
          prepareCollectionRestoreCommands(input, 'now'),
          throwsA(isA<TypeError>()),
        );
      }
    },
  );
}
