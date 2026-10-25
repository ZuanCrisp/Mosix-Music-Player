import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this._path);
  final String _path;
  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
  @override
  Future<String?> getTemporaryPath() async => _path;
}

class _Settings extends SettingsNotifier {
  _Settings(this._directory, this._concurrency, this._nativeWorker);
  final String _directory;
  final int _concurrency;
  final bool _nativeWorker;
  @override
  AppSettings build() => AppSettings(
    downloadDirectory: _directory,
    filenameFormat: '{title}',
    singleFilenameFormat: '{title}',
    embedMetadata: true,
    embedLyrics: false,
    embedReplayGain: true,
    nativeDownloadWorkerEnabled: _nativeWorker,
    concurrentDownloads: _concurrency,
    autoFallback: false,
    lyricsProviders: const [],
    motionArtworkEnabled: false,
  );
}

class _SimultaneousHistory extends DownloadHistoryNotifier {
  final _bothSaved = Completer<void>();
  var _saved = 0;

  @override
  Future<void> addToHistory(
    DownloadHistoryItem item, {
    bool preserveTrackVariant = false,
  }) async {
    await super.addToHistory(item, preserveTrackVariant: preserveTrackVariant);
    if (++_saved == 2) _bothSaved.complete();
    // Both real SQLite writes finish before either caller publishes completion.
    // This deliberately exposes concurrent finalization, independently of I/O speed.
    await _bothSaved.future;
  }
}

class _FailOnceHistory extends DownloadHistoryNotifier {
  var _failed = false;

  @override
  Future<void> addToHistory(
    DownloadHistoryItem item, {
    bool preserveTrackVariant = false,
  }) async {
    if (!_failed && item.trackName.endsWith('-1')) {
      _failed = true;
      throw StateError('Fixture: history temporarily unavailable');
    }
    await super.addToHistory(item, preserveTrackVariant: preserveTrackVariant);
  }
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'example.audio',
        name: 'example.audio',
        displayName: 'Example Audio',
        version: '1',
        description: 'Local audio fixture',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        skipMetadataEnrichment: true,
      ),
    ],
  );
}

Future<String> _ffmpeg(List<String> arguments) async {
  final session = await FFmpegKit.executeWithArguments(arguments);
  final output = await session.getOutput() ?? '';
  expect(
    ReturnCode.isSuccess(await session.getReturnCode()),
    true,
    reason: output,
  );
  return output;
}

Future<String> _pcmHash(String path) async {
  // FFmpegKit's log callback does not capture muxer stdout on every platform.
  final checksum = File('$path.pcm.md5');
  try {
    await _ffmpeg([
      '-y',
      '-v',
      'error',
      '-i',
      path,
      '-map',
      '0:a:0',
      '-f',
      'md5',
      checksum.path,
    ]);
    final output = await checksum.readAsString();
    expect(output, matches(r'MD5=[a-f0-9]+'));
    return output.trim();
  } finally {
    if (await checksum.exists()) await checksum.delete();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const baseline = bool.fromEnvironment('REPLAYGAIN_COMPLETION_BASELINE');
  final results = <Map<String, dynamic>>[];
  late Directory root;
  late Directory output;
  late PathProviderPlatform originalPaths;
  final hashes = <String>[];
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('album-rg-completion-');
    output = await Directory('${root.path}/output').create();
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
    });
    final extensions = await Directory('${root.path}/extensions').create();
    final data = await Directory('${root.path}/data').create();
    await PlatformBridge.initExtensionSystem(
      extensions.path,
      data.path,
      masterKey: base64Encode(List<int>.filled(32, 1)),
      lyricsProviders: const [],
      lyricsFetchOptions: const {},
      allowedDirectories: [output.path],
    );
    final audio = <String>[];
    for (var i = 0; i < 2; i++) {
      final path = '${root.path}/fixture-$i.flac';
      await _ffmpeg([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=${440 + i * 220}:sample_rate=44100',
        '-t',
        '${2 + i}',
        '-af',
        'volume=${i == 0 ? 1 : 0.25}',
        '-c:a',
        'flac',
        path,
      ]);
      audio.add(base64Encode(await File(path).readAsBytes()));
      hashes.add(await _pcmHash(path));
    }
    final provider = await Directory(
      '${extensions.path}/example.audio',
    ).create();
    await File('${provider.path}/manifest.json').writeAsString(
      jsonEncode({
        'name': 'example.audio',
        'version': '1',
        'description': 'Local album ReplayGain completion fixture',
        'type': ['download_provider'],
        'permissions': {'file': true},
        'skipMetadataEnrichment': true,
      }),
    );
    await File('${provider.path}/index.js').writeAsString('''
registerExtension({
  checkAvailability(id) { return { available: true, track_id: id }; },
  download(trackId, quality, outputPath) {
    const audio = ${jsonEncode(audio)};
    const index = String(trackId).endsWith('one') ? 0 : 1;
    file.writeBytes(outputPath, audio[index]);
    return { success: true, file_path: outputPath, actual_extension: '.flac' };
  }
});
''');
    await PlatformBridge.loadExtensionsFromDir(extensions.path);
    await PlatformBridge.setExtensionEnabled('example.audio', true);
    LogBuffer.loggingEnabled = true;
  });
  tearDownAll(() async {
    await PlatformBridge.cleanupExtensions();
    LogBuffer.loggingEnabled = false;
    await HistoryDatabase.instance.close();
    await (await AppStateDatabase.instance.database).close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
    binding.reportData ??= {};
    binding.reportData!['album_replaygain_completion'] = {
      'platform': Platform.operatingSystem,
      'baseline_observation': baseline,
      'completed_cases': results.length,
      'cases': results,
    };
  });
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  final configurations = [
    for (final nativeWorker in [false, if (Platform.isAndroid) true])
      for (final concurrency in [1, 2])
        (
          nativeWorker: nativeWorker,
          concurrency: concurrency,
          lateTrack: false,
          retry: false,
        ),
    (nativeWorker: false, concurrency: 2, lateTrack: true, retry: false),
    (nativeWorker: false, concurrency: 1, lateTrack: false, retry: true),
  ];
  for (final config in configurations) {
    final concurrency = config.concurrency;
    final name =
        '${config.nativeWorker ? 'native' : 'foreground'}-$concurrency'
        '${config.lateTrack ? '-late' : ''}${config.retry ? '-retry' : ''}';
    testWidgets('full queue album completion, $name', (tester) async {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(output.path, concurrency, config.nativeWorker),
          ),
          extensionProvider.overrideWith(_Extensions.new),
          if (concurrency == 2 && !config.nativeWorker)
            downloadHistoryProvider.overrideWith(_SimultaneousHistory.new),
          if (config.retry)
            downloadHistoryProvider.overrideWith(_FailOnceHistory.new),
        ],
      );
      final files = <String, String>{};
      final states = <String, List<String>>{};
      var candidateChecks = 0;
      var candidatesMatch = true;
      final tracks = [
        for (var i = 0; i < 2; i++)
          Track(
            id: 'example.audio:$name-${i == 0 ? 'one' : 'two'}',
            name: 'Track $name-$i',
            artistName: 'Artist',
            albumArtist: 'Artist',
            albumName: 'Album $name',
            albumId: 'album-$name',
            source: 'example.audio',
            duration: 2 + i,
            trackNumber: i + 1,
            totalTracks: 2,
          ),
      ];
      final albumMessage = 'Album ReplayGain for "id:album-$name":';
      void addDuringWrite() {
        if (!config.lateTrack ||
            tracks.length == 3 ||
            !LogBuffer().entries.any((e) => e.message.contains(albumMessage))) {
          return;
        }
        final extra = tracks.first.copyWith(
          id: 'example.audio:$name-extra-one',
          name: 'Track $name-extra',
        );
        tracks.add(extra);
        container.read(downloadQueueProvider.notifier).addMultipleToQueue([
          extra,
        ], 'example.audio');
      }

      LogBuffer().addListener(addDuringWrite);
      try {
        final queue = container.read(downloadQueueProvider.notifier);
        queue.pauseQueue(persistAcrossRestarts: false);
        queue.addMultipleToQueue(tracks, 'example.audio');
        await queue.flushQueuePersistence();
        var done = Completer<void>();
        var retried = false;
        String? failedId;
        final subscription = container.listen(downloadQueueProvider, (_, next) {
          candidateChecks++;
          candidatesMatch =
              candidatesMatch &&
              identical(
                next.lookup.firstDownloading,
                next.items
                    .where((item) => item.status == DownloadStatus.downloading)
                    .firstOrNull,
              ) &&
              identical(
                next.lookup.firstFinalizing,
                next.items
                    .where((item) => item.status == DownloadStatus.finalizing)
                    .firstOrNull,
              ) &&
              orderedEquals(
                next.items.where(
                  (item) => item.status == DownloadStatus.queued,
                ),
              ).matches(next.queuedItems, {});
          for (final item in next.items) {
            final transitions = states.putIfAbsent(item.track.id, () => []);
            if (transitions.lastOrNull != item.status.name) {
              transitions.add(item.status.name);
            }
            if (item.status == DownloadStatus.completed) {
              files[item.track.id] = item.filePath!;
            } else if (item.status == DownloadStatus.failed &&
                !done.isCompleted) {
              if (config.retry && !retried) {
                expect(item.error, contains('history temporarily unavailable'));
                failedId = item.id;
              } else {
                done.completeError(
                  StateError('${item.track.id}: ${item.error}'),
                );
              }
            }
          }
          if (failedId != null &&
              !retried &&
              !next.isProcessing &&
              !done.isCompleted) {
            done.complete();
          }
          if (files.length == tracks.length &&
              next.items.isEmpty &&
              !next.isProcessing &&
              !done.isCompleted) {
            done.complete();
          }
        });
        try {
          queue.resumeQueue();
          await done.future.timeout(const Duration(seconds: 60));
          if (config.retry) {
            expect(files, hasLength(1));
            expect(container.read(downloadQueueProvider).failedCount, 1);
            final savedTags = await PlatformBridge.readFileMetadata(
              files.values.single,
            );
            expect(savedTags['replaygain_album_gain'], anyOf(isNull, isEmpty));
            expect(
              LogBuffer().entries.where(
                (e) => e.message.contains(albumMessage),
              ),
              isEmpty,
            );
            retried = true;
            done = Completer<void>();
            await queue.retryItem(failedId!);
            await done.future.timeout(const Duration(seconds: 60));
          }
          await queue.flushQueuePersistence();
          expect(candidateChecks, greaterThan(0));
          expect(
            candidatesMatch,
            isTrue,
            reason:
                'Cached notification candidates must match each real queue snapshot',
          );
        } finally {
          subscription.close();
        }
        final metadata = <Map<String, dynamic>>[];
        for (var i = 0; i < tracks.length; i++) {
          final path = files[tracks[i].id]!;
          final tags = await PlatformBridge.readFileMetadata(path);
          expect(
            tags['replaygain_track_gain'],
            isNotEmpty,
            reason: '$name track gain',
          );
          expect(
            tags['replaygain_track_peak'],
            isNotEmpty,
            reason: '$name track peak',
          );
          expect(await _pcmHash(path), hashes[i == 2 ? 0 : i]);
          final history = await container
              .read(downloadHistoryProvider.notifier)
              .getByFilePathAsync(path);
          expect(history?.filePath, path);
          if (!baseline) {
            expect(
              tags['replaygain_album_gain'],
              isNotEmpty,
              reason: '$name album gain',
            );
            expect(
              tags['replaygain_album_peak'],
              isNotEmpty,
              reason: '$name album peak',
            );
          }
          metadata.add({
            'track_gain': tags['replaygain_track_gain'],
            'track_peak': tags['replaygain_track_peak'],
            'album_gain': tags['replaygain_album_gain'],
            'album_peak': tags['replaygain_album_peak'],
            'pcm_unchanged': true,
            'history_persisted': true,
          });
        }
        if (!baseline) {
          var power = 0.0;
          var duration = 0;
          var peak = 0.0;
          for (var i = 0; i < tracks.length; i++) {
            final gain = double.parse(
              (metadata[i]['track_gain'] as String).replaceAll(' dB', ''),
            );
            power += math.pow(10, (-18 - gain) / 10) * tracks[i].duration;
            duration += tracks[i].duration;
            peak = math.max(
              peak,
              double.parse(metadata[i]['track_peak'] as String),
            );
          }
          final gain = -18 - 10 * math.log(power / duration) / math.ln10;
          final expectedGain =
              '${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(2)} dB';
          for (final tags in metadata) {
            expect(tags['album_gain'], expectedGain);
            expect(tags['album_peak'], peak.toStringAsFixed(6));
          }
          expect(tracks.length, config.lateTrack ? 3 : 2);
          expect(
            LogBuffer().entries.where((e) => e.message.contains(albumMessage)),
            hasLength(config.nativeWorker ? 0 : (config.lateTrack ? 2 : 1)),
          );
          if (config.nativeWorker) {
            expect(
              LogBuffer().entries.any(
                (e) => e.message.contains(
                  'Starting Android native download worker',
                ),
              ),
              true,
            );
          }
        }
        results.add({
          'name': name,
          'concurrency': concurrency,
          'tags': metadata,
          'transitions': states,
        });
      } finally {
        LogBuffer().removeListener(addDuringWrite);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (container.read(downloadQueueProvider).isProcessing &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        container.dispose();
      }
    });
  }
}
