import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/download_history_provider.dart';
import 'package:mosix/screens/track_metadata_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zuancrisp.mosix/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final scenario in [
    'fallback',
    'local',
    'instrumental',
    'empty',
    'unavailable',
  ]) {
    testWidgets('metadata reads local lyrics: $scenario', (tester) async {
      SharedPreferences.setMockInitialValues({});
      const path = 'content://library/document/song.flac';
      const lyrics = '[00:01.00]A locally stored lyric line';
      var metadataReads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'safStat':
            return jsonEncode({'exists': true, 'size': 100});
          case 'readAudioMetadata':
            return '{}';
          case 'getLyricsLRCWithSource':
            // Opening metadata must never trigger an online lyrics request.
            expect((call.arguments as Map)['file_path'], path);
            if (scenario == 'unavailable') {
              throw PlatformException(code: 'backend_unavailable');
            }
            return jsonEncode({
              'lyrics': scenario == 'instrumental'
                  ? '[instrumental:true]'
                  : scenario == 'local'
                  ? lyrics
                  : '',
              'source': scenario == 'local' ? 'Embedded' : '',
            });
          case 'readFileMetadata':
            expect((call.arguments as Map)['file_path'], path);
            metadataReads++;
            return jsonEncode({'lyrics': scenario == 'empty' ? '' : lyrics});
          case 'getSafFileModTimes':
            return '{}';
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final item = DownloadHistoryItem(
        id: 'local-song',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: path,
        service: 'example-provider',
        downloadedAt: DateTime(2026),
        format: 'flac',
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TrackMetadataScreen(item: item),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        metadataReads,
        ['local', 'instrumental'].contains(scenario) ? 0 : 1,
      );
      expect(
        find.text('A locally stored lyric line'),
        ['empty', 'instrumental'].contains(scenario)
            ? findsNothing
            : findsOneWidget,
      );
      expect(
        find.text('Instrumental track'),
        scenario == 'instrumental' ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('No lyrics found in this file'),
        scenario == 'empty' ? findsOneWidget : findsNothing,
      );
      expect(find.text('Embed Lyrics'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
