import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/network_storage_service.dart';

import '../test/support/library_collections_benchmark.dart';
import '../test/support/smb_listing_benchmark.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'SMB result adapter/sort only, no live server or network throughput/FPS claim.',
  };
  var completed = 0;
  tearDownAll(() {
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['smb_listing'] = report;
  });
  for (final count in [32, 256, 1024, 4096, 10000, 50000]) {
    testWidgets('prepare $count SMB entries', (tester) async {
      final input = await compute(smbListingFixture, count);
      final expected = smbListingRows(legacySmbListing(input));
      final samples = <String, List<Map<String, int>>>{
        for (final kind in ['legacy', 'current']) kind: [],
      };
      legacySmbListing(input);
      await NetworkStorageService.prepareSmbEntries(input.files, input.path);
      for (var pair = 0; pair < 5; pair++) {
        for (final kind
            in pair.isEven ? samples.keys : samples.keys.toList().reversed) {
          final result = await measureCollectionOperation<List<NetworkEntry>>(
            () => switch (kind) {
              'legacy' => legacySmbListing(input),
              _ => NetworkStorageService.prepareSmbEntries(
                input.files,
                input.path,
              ),
            },
          );
          expect(smbListingRows(result.value), expected);
          expect(input.files.length, count);
          samples[kind]!.add(result.timing);
        }
      }
      report['entries_$count'] = samples;
      completed++;
    });
  }
}
