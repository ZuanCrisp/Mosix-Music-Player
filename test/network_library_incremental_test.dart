import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_ingestion_store.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';

import 'support/library_native_fixture.dart';
import 'support/sqlite_process_database.dart';

class _Storage extends NetworkStorageService {
  _Storage(this.protocol);

  final NetworkProtocol protocol;
  final tree = <String, List<NetworkEntry>>{};
  final failedFolders = <String>{};
  String server = 'nas.test';
  int listings = 0;

  @override
  Future<NetworkConnection> connection(String id) async => NetworkConnection(
    id: id,
    name: 'NAS',
    protocol: protocol,
    address: protocol == NetworkProtocol.smb
        ? 'smb://$server/music/'
        : 'https://$server/music/',
  );

  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection connection, [
    String path = '',
  ]) async {
    listings++;
    if (failedFolders.contains(path)) throw const SocketException('offline');
    return tree[path] ?? [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final protocol in [NetworkProtocol.smb, NetworkProtocol.webdav]) {
    group('incremental ${protocol.name}', () {
      late Directory directory;
      late SqliteProcessDatabase database;
      late LibraryIngestionStore store;
      late _Storage storage;
      final reads = <String>[];
      final lookupSizes = <int>[];
      final failedTracks = <String>{};
      String? coverPath;
      var lookupFailure = false;
      var cancelled = false;
      void Function()? afterLookup;

      NetworkEntry track(
        String name, {
        int? size = 100,
        int? modified = 1000,
        String? etag,
      }) => NetworkEntry(
        name,
        name.split('/').last,
        size: size,
        modifiedTime: modified,
        etag: etag,
      );

      setUp(() async {
        directory = await Directory.systemTemp.createTemp('nas-incremental-');
        database = await SqliteProcessDatabase.open();
        await createNativeLibraryFixture(database);
        store = LibraryIngestionStore(
          openDatabase: () async => database,
          ensureHistoryAttached: (_) async {},
        );
        storage = _Storage(protocol);
        reads.clear();
        lookupSizes.clear();
        failedTracks.clear();
        coverPath = null;
        lookupFailure = false;
        cancelled = false;
        afterLookup = null;
      });
      tearDown(() async {
        await storage.dispose();
        await database.close();
        await directory.delete(recursive: true);
      });

      Future<LibraryScanNDJSONFile> scan({
        bool force = false,
        bool commit = true,
        String root = '',
      }) async {
        // A fresh reader per scan proves reuse comes from persisted Library
        // rows, rather than the playback service's short-lived memory cache.
        final scanner = NetworkLibraryScanner(
          storage: storage,
          supportDirectory: () async => directory,
          temporaryDirectory: () async => directory,
          readCachedRows: (paths) async {
            lookupSizes.add(paths.length);
            if (lookupFailure) throw StateError('cache query failed');
            final rows = await store.readNetworkScanRows('source', paths);
            afterLookup?.call();
            return rows;
          },
          readMetadata: (source) async {
            final name = Uri.parse(source).pathSegments.last;
            reads.add(name);
            if (failedTracks.contains(name)) throw StateError('unreadable');
            return {
              'title': 'Revision ${reads.length}: $name',
              'artist': 'Artist',
              'lyrics': '[00:01.00]Lyrics',
              'replaygain_track_gain': '-4 dB',
              'cover_path': ?coverPath,
            };
          },
        );
        final result = await scanner.scan(
          NetworkStorageService.source('nas', root),
          forceFullScan: force,
          checkpoint: () async {
            if (cancelled) throw StateError('cancelled');
          },
          onProgress: (_, _, _) {},
        );
        if (commit) {
          await store.replaceSourceStream(
            'source',
            result.rows(),
            preserveMissing: result.errorCount > 0,
            preserveMissingPaths: result.preserveMissingPaths,
          );
        }
        return result;
      }

      test('persisted rows skip unchanged files in bounded batches', () async {
        storage.tree[''] = List.generate(130, (i) => track('$i.flac'));
        final first = await scan();
        final original = await first.rows().toList();
        expect(reads, hasLength(130));
        expect(lookupSizes, [64, 64, 2]);
        expect(
          original.every((row) => row['networkFileVersion'] != null),
          true,
        );
        final persisted = await database.query('library');
        expect(
          await store.readNetworkScanRows('other', ['network://nas/0.flac']),
          isEmpty,
        );
        reads.clear();
        lookupSizes.clear();

        final second = await scan();
        expect(reads, isEmpty);
        expect(lookupSizes, [64, 64, 2]);
        expect(second.expectedCount, 130);
        expect(await database.query('library'), persisted);
        expect(storage.listings, 2);
        final rows = await database.query('library');
        expect(rows, hasLength(130));
        expect(rows.every((row) => row['has_lyrics'] == 1), true);
        expect(rows.every((row) => row['has_replaygain'] == 1), true);
      });

      test(
        'new, changed and removed files reconcile without rereading others',
        () async {
          storage.tree[''] = [
            track('same.flac'),
            track('edit.flac'),
            track('delete.flac'),
          ];
          await scan();
          reads.clear();
          storage.tree[''] = [
            track('same.flac'),
            track('edit.flac', modified: 2000),
            track('new.flac'),
          ];
          final changed = await scan();
          expect(reads, ['edit.flac', 'new.flac']);
          expect(changed.errorCount, 0);
          expect((await database.query('library')).map((r) => r['file_path']), [
            'network://nas/same.flac',
            'network://nas/edit.flac',
            'network://nas/new.flac',
          ]);
          reads.clear();
          await scan();
          expect(reads, isEmpty);

          storage.tree['']![0] = track('same.flac', size: 101);
          await scan();
          expect(reads, ['same.flac']);
        },
      );

      test(
        'force full scan bypasses lookups and refreshes the next cache',
        () async {
          storage.tree[''] = [track('song.flac')];
          await scan();
          reads.clear();
          lookupSizes.clear();
          lookupFailure = true;
          await scan(force: true);
          expect(reads, ['song.flac']);
          expect(lookupSizes, isEmpty);
          lookupFailure = false;
          reads.clear();
          await scan();
          expect(reads, isEmpty);
        },
      );

      test(
        'unknown validators rescan while strong ETags detect tag edits',
        () async {
          storage.tree[''] = [
            track('unknown.flac', modified: null),
            track('zero.flac', modified: 0),
            track('weak.flac', size: null, modified: null, etag: 'W/"one"'),
            track('etag.flac', size: null, modified: null, etag: '"one"'),
          ];
          await scan();
          reads.clear();
          await scan();
          expect(reads, ['unknown.flac', 'zero.flac', 'weak.flac']);
          reads.clear();
          storage.tree['']![3] = track(
            'etag.flac',
            size: null,
            modified: null,
            etag: '"two"',
          );
          await scan();
          expect(reads, contains('etag.flac'));
        },
      );

      test(
        'partial failures retain old rows and retry changed metadata',
        () async {
          storage.tree[''] = [
            track('same.flac'),
            track('bad.flac'),
            track('missing.flac'),
          ];
          await scan();
          reads.clear();
          storage.tree[''] = [
            track('same.flac'),
            track('bad.flac', modified: 2000),
          ];
          failedTracks.add('bad.flac');
          final partial = await scan();
          expect(partial.errorCount, 1);
          expect(reads, ['bad.flac']);
          expect(await database.query('library'), hasLength(2));
          expect(
            (await database.query('library')).map((row) => row['file_path']),
            isNot(contains('network://nas/missing.flac')),
          );
          failedTracks.clear();
          reads.clear();
          await scan();
          expect(reads, ['bad.flac']);
          expect(await database.query('library'), hasLength(2));
        },
      );

      test(
        'changed weak ETag invalidates an otherwise matching dated size',
        () async {
          storage.tree[''] = [track('song.flac', etag: 'W/"one"')];
          await scan();
          reads.clear();
          await scan();
          expect(reads, isEmpty);
          storage.tree[''] = [track('song.flac', etag: 'W/"two"')];
          await scan();
          expect(reads, ['song.flac']);
        },
      );

      test(
        'failed listing and unpublished staging never replace the cache',
        () async {
          storage.tree[''] = [track('song.flac')];
          await scan();
          final original = await database.query('library');
          storage.failedFolders.add('');
          await expectLater(scan(), throwsA(isA<SocketException>()));
          expect(await database.query('library'), original);
          storage.failedFolders.clear();
          storage.tree[''] = [track('song.flac', modified: 2000)];
          await scan(commit: false);
          expect(await database.query('library'), original);
          reads.clear();
          await scan();
          expect(reads, ['song.flac']);
        },
      );

      test(
        'failed child listing retains its cached rows until a successful scan',
        () async {
          storage.tree[''] = [
            track('root.flac'),
            const NetworkEntry('nested/', 'nested', directory: true),
          ];
          storage.tree['nested/'] = [track('nested/song.flac')];
          await scan();
          reads.clear();
          storage.failedFolders.add('nested/');
          final partial = await scan();
          expect(partial.errorCount, 1);
          expect(reads, isEmpty);
          expect(await database.query('library'), hasLength(2));
          storage.failedFolders.clear();
          storage.tree['nested/'] = [];
          await scan();
          expect(
            (await database.query('library')).single['file_path'],
            'network://nas/root.flac',
          );
        },
      );

      test(
        'partial scan removes a deleted folder but retains failed scopes',
        () async {
          storage.tree[''] = [
            const NetworkEntry('test/', 'test', directory: true),
            const NetworkEntry('offline%_/', 'offline%_', directory: true),
            track('unreadable.flac'),
          ];
          storage.tree['test/'] = [track('test/stale.flac')];
          storage.tree['offline%_/'] = [track('offline%_/keep.flac')];
          await scan();
          storage.tree['']!.removeAt(0);
          storage.tree['']![1] = track('unreadable.flac', modified: 2000);
          storage.failedFolders.add('offline%_/');
          failedTracks.add('unreadable.flac');
          final result = await scan();
          expect(result.errorCount, 2);
          expect(
            (await database.query('library')).map((row) => row['file_path']),
            unorderedEquals([
              'network://nas/offline%25_/keep.flac',
              'network://nas/unreadable.flac',
            ]),
          );
        },
      );

      test('selected NAS folders stay scoped to their own subtree', () async {
        storage.tree[''] = [
          const NetworkEntry('downloads/', 'downloads', directory: true),
          const NetworkEntry('processed/', 'processed', directory: true),
        ];
        storage.tree['downloads/'] = [track('downloads/original.flac')];
        storage.tree['processed/'] = [track('processed/converted.flac')];
        for (final folder in ['downloads/', 'processed/']) {
          reads.clear();
          final result = await scan(root: folder, commit: false);
          final rows = await result.rows().toList();
          expect(rows, hasLength(1));
          expect(rows.single['filePath'], startsWith('network://nas/$folder'));
          expect(reads, hasLength(1));
        }
      });

      test(
        'cancellation after cache lookup discards staging and preserves rows',
        () async {
          storage.tree[''] = [track('song.flac')];
          await scan();
          final original = await database.query('library');
          final outputs = await Directory(
            '${directory.path}/network_scans',
          ).list().length;
          reads.clear();
          afterLookup = () => cancelled = true;
          await expectLater(scan(), throwsStateError);
          expect(reads, isEmpty);
          expect(await database.query('library'), original);
          expect(
            await Directory('${directory.path}/network_scans').list().length,
            outputs,
          );
        },
      );

      test(
        'missing artwork is recovered and changed server identity invalidates rows',
        () async {
          storage.tree[''] = [track('song.flac')];
          coverPath = (await File(
            '${directory.path}/embedded.image',
          ).writeAsBytes([1, 2, 3])).path;
          final first = await scan();
          final row = (await first.rows().toList()).single;
          reads.clear();
          await scan();
          expect(reads, isEmpty);
          await File(row['coverPath'] as String).delete();
          await scan();
          expect(reads, ['song.flac']);
          reads.clear();
          storage.server = 'replacement.test';
          await scan();
          expect(reads, ['song.flac']);
        },
      );

      test(
        'cache lookup failure aborts without publishing an empty source',
        () async {
          storage.tree[''] = [track('song.flac')];
          await scan();
          final original = await database.query('library');
          lookupFailure = true;
          await expectLater(scan(), throwsStateError);
          expect(await database.query('library'), original);
        },
      );
    });
  }
}
