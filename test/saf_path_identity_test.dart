import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/utils/path_match_keys.dart';

String _document(String authority, String id, {String? tree}) => Uri(
  scheme: 'content',
  host: authority,
  pathSegments: [
    if (tree != null) ...['tree', tree],
    'document',
    id,
  ],
).toString();

void main() {
  const provider = 'org.example.documents';
  const documentId = 'account:Music/Album/01 Song.flac';
  final parent = _document(provider, documentId, tree: 'account:Music');
  final album = _document(provider, documentId, tree: 'account:Music/Album');
  final direct = _document(provider, documentId);

  test('one provider document matches through different selected trees', () {
    expect(
      buildPhysicalPathMatchKeys(parent),
      contains('saf-document:b3JnLmV4YW1wbGUuZG9jdW1lbnRz:$documentId'),
    );
    expect(physicalFilePathsMatch(parent, album), isTrue);
    expect(physicalFilePathsMatch(parent, direct), isTrue);
    expect(physicalFilePathsMatch(album, direct), isTrue);
  });

  test('document identities preserve literal percent signs and Unicode', () {
    const id = 'account:Music/夜/100%20 Real.flac';
    expect(
      physicalFilePathsMatch(
        _document(provider, id, tree: 'account:Music'),
        _document(provider, id, tree: 'account:Music/夜'),
      ),
      isTrue,
    );
    expect(
      physicalFilePathsMatch(
        _document(provider, id, tree: 'account:Music'),
        _document(provider, 'account:Music/夜/100 Real.flac'),
      ),
      isFalse,
    );
  });

  test('different providers, accounts and documents remain distinct', () {
    for (final other in [
      _document('org.other.documents', documentId, tree: 'account:Music'),
      _document(
        provider,
        'other:Music/Album/01 Song.flac',
        tree: 'other:Music',
      ),
      _document(
        provider,
        'account:Music/Other/01 Song.flac',
        tree: 'account:Music',
      ),
      _document(
        provider,
        'account:Music/Album/01 Song.opus',
        tree: 'account:Music',
      ),
    ]) {
      expect(physicalFilePathsMatch(parent, other), isFalse);
    }
  });

  test('opaque document IDs keep their case across tree aliases', () {
    expect(
      physicalFilePathsMatch(
        _document(provider, 'Opaque-A', tree: 'parent'),
        _document(provider, 'opaque-a', tree: 'child'),
      ),
      isFalse,
    );
  });

  test('arbitrary content paths do not gain a document identity', () {
    expect(
      physicalFilePathsMatch(
        'content://$provider/album/one/document/42',
        'content://$provider/album/two/document/42',
      ),
      isFalse,
    );
  });

  test('download history recognizes a redownload through another tree', () {
    DownloadHistoryItem item(String id, String path, String albumName) =>
        DownloadHistoryItem(
          id: id,
          trackName: 'Song',
          artistName: 'Artist',
          albumName: albumName,
          filePath: path,
          service: 'test-provider',
          downloadedAt: DateTime.utc(2026, 10, 3),
        );

    expect(
      historyItemsReferToSameStoredFile(
        item('old-id', parent, 'Album'),
        item('new-id', album, 'Unknown Album'),
      ),
      isTrue,
    );
  });
}
