import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_storage_service.dart';

import 'support/vm_service_probe.dart';

class _TransientListingStorage extends NetworkStorageService {
  _TransientListingStorage(this.protocol, this.collect);

  final NetworkProtocol protocol;
  final Future<void> Function() collect;
  WeakReference<List<NetworkEntry>>? rootListing;
  bool? rootWasReleased;

  @override
  Future<NetworkConnection> connection(String id) async => NetworkConnection(
    id: id,
    name: 'Fixture',
    protocol: protocol,
    address: protocol == NetworkProtocol.smb
        ? 'smb://example.test/music/'
        : 'https://example.test/music/',
  );

  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection connection, [
    String path = '',
  ]) async {
    if (path.isEmpty) {
      final entries = [
        const NetworkEntry('child/', 'child', directory: true),
        for (var i = 0; i < 4000; i++) NetworkEntry('$i.flac', '$i.flac'),
      ];
      rootListing = WeakReference(entries);
      return entries;
    }
    await collect();
    rootWasReleased = rootListing!.target == null;
    return [const NetworkEntry('child/song.flac', 'song.flac')];
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = (await developer.Service.getInfo()).serverUri;
  for (final protocol in [NetworkProtocol.smb, NetworkProtocol.webdav]) {
    test(
      '${protocol.name} scan releases completed directory listings before finishing',
      () async {
        final overrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = overrides);
        final directory = await Directory.systemTemp.createTemp(
          'network-library-memory-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final storage = _TransientListingStorage(
          protocol,
          () => collectTestGarbage(service!),
        );
        addTearDown(storage.dispose);
        final result =
            await NetworkLibraryScanner(
              storage: storage,
              readMetadata: (_) async => {'title': 'Track'},
              supportDirectory: () async => directory,
              temporaryDirectory: () async => directory,
            ).scan(
              NetworkStorageService.source('fixture', ''),
              checkpoint: () async {},
              onProgress: (_, _, _) {},
            );
        expect(result.expectedCount, 4001);
        expect(result.errorCount, 0);
        expect(
          storage.rootWasReleased,
          isTrue,
          reason: 'A completed root listing must not stay alive in child scans',
        );
        await result.delete();
      },
      skip: service == null
          ? 'Requires flutter test --enable-vmservice'
          : false,
    );
  }
}
