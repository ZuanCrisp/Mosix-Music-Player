import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/file_access.dart';

void main() {
  group('Finalized SAF audio names', () {
    for (final extension in ['mp3', 'opus', 'flac', 'ogg', 'm4a', 'mp4']) {
      test(
        'publishes the final $extension container instead of source M4A',
        () {
          expect(
            finalizedAudioFileName(
              fileName: 'Example song.m4a',
              localPath: '/cache/final_audio.$extension',
              fallbackExtension: '.m4a',
            ),
            'Example song.$extension',
          );
        },
      );
    }
    test('preserves variant labels and normalizes uppercase suffixes', () {
      expect(
        finalizedAudioFileName(
          fileName: 'Song [OPUS 256kbps].m4a',
          localPath: '/cache/final.OPUS',
          fallbackExtension: '.m4a',
        ),
        'Song [OPUS 256kbps].opus',
      );
    });
    test(
      'uses the reported container when the temporary path has no suffix',
      () {
        expect(
          finalizedAudioFileName(
            fileName: 'Song',
            localPath: '/cache/final_audio',
            fallbackExtension: '.m4a',
          ),
          'Song.m4a',
        );
      },
    );
  });

  group('file deletion', () {
    test('confirms a local file is absent before reporting success', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'mornye-delete-test-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final file = File('${tempDir.path}${Platform.pathSeparator}track.flac');
      await file.writeAsBytes([1, 2, 3]);

      expect(await deleteFile(file.path), isTrue);
      expect(await file.exists(), isFalse);
      expect(await deleteFile(file.path), isTrue);
    });

    test('refuses to delete a virtual CUE track path', () async {
      expect(await deleteFile('/music/album.cue#track01'), isFalse);
    });
  });

  group('native worker progress', () {
    test('does not publish 100 percent while finalization is pending', () {
      expect(nativeWorkerFinalizingProgress(0), 0.95);
      expect(nativeWorkerFinalizingProgress(0.7), 0.7);
      expect(nativeWorkerFinalizingProgress(1), 0.99);
    });
  });

  group('storage write failure detection', () {
    test('recognizes typed and common Android filesystem failures', () {
      expect(
        isStorageWriteFailure(
          errorType: 'permission',
          errorMessage: 'provider-specific text',
        ),
        isTrue,
      );
      expect(
        isStorageWriteFailure(
          errorMessage:
              'failed to create file: open /storage/song.flac.partial: '
              'operation not permitted',
        ),
        isTrue,
      );
      expect(
        isStorageWriteFailure(
          errorMessage:
              'Native finalization failed: failed to publish deferred SAF output',
        ),
        isTrue,
      );
    });

    test(
      'does not mistake provider or network failures for storage errors',
      () {
        expect(
          isStorageWriteFailure(
            errorType: 'api_error',
            errorMessage: 'HTTP 404 for /download',
          ),
          isFalse,
        );
        expect(
          isStorageWriteFailure(
            errorType: 'network',
            errorMessage: 'Connection reset by peer',
          ),
          isFalse,
        );
      },
    );
  });

  group('quality variant filenames', () {
    test('estimates average bitrate without decoding the audio file', () {
      expect(
        estimateAverageBitrateKbps(
          fileSizeBytes: 42.9 * 1000 * 1000 ~/ 1,
          durationSeconds: 204,
        ),
        1682,
      );
      expect(
        estimateAverageBitrateKbps(fileSizeBytes: null, durationSeconds: 204),
        isNull,
      );
      expect(
        estimateAverageBitrateKbps(
          fileSizeBytes: 42 * 1000 * 1000,
          durationSeconds: 0,
        ),
        isNull,
      );
    });

    test('uses measured lossless specifications instead of request labels', () {
      expect(
        buildQualityVariantFilenameLabel(
          detectedFormat: 'flac',
          bitDepth: 24,
          sampleRate: 96000,
          measuredQuality: 'LOSSLESS',
        ),
        '24bit-96kHz',
      );
      expect(
        buildQualityVariantFilenameLabel(
          detectedFormat: 'flac',
          measuredQuality: 'LOSSLESS',
        ),
        isNull,
      );
    });

    test('uses measured bitrate for lossy output', () {
      expect(
        buildQualityVariantFilenameLabel(
          detectedFormat: 'mp3',
          bitrateKbps: 320,
        ),
        '320kbps',
      );
      expect(
        buildQualityVariantFilenameLabel(
          detectedFormat: 'opus',
          measuredQuality: 'OPUS 256kbps',
        ),
        '256kbps',
      );
    });

    test('creates a stable temporary token and replaces only that token', () {
      final token = qualityVariantStagingLabel('queue-item-1');
      expect(token, matches(RegExp(r'^qv_[0-9a-f]{8}$')));
      expect(qualityVariantStagingLabel('queue-item-1'), token);
      expect(
        applyQualityVariantFilenameLabel(
          fileName: 'Artist - Song - $token.flac',
          stagingLabel: token,
          qualityLabel: '16bit-44.1kHz',
        ),
        'Artist - Song - 16bit-44.1kHz.flac',
      );
      expect(
        applyQualityVariantFilenameLabel(
          fileName: 'Post Processed Song.flac',
          stagingLabel: token,
          qualityLabel: '16bit-44.1kHz',
        ),
        'Post Processed Song - 16bit-44.1kHz.flac',
      );
    });

    test('adds measured quality only when a clean filename collides', () {
      const staging = 'qv_12345678';
      const stagedName = 'Artist - Song - qv_12345678.flac';
      expect(
        removeQualityVariantStagingLabel(
          fileName: stagedName,
          stagingLabel: staging,
        ),
        'Artist - Song.flac',
      );
      expect(
        resolveQualityVariantFilename(
          fileName: stagedName,
          stagingLabel: staging,
          qualityLabel: '24bit-96kHz',
          collisionOnly: true,
          cleanNameExists: false,
        ),
        'Artist - Song.flac',
      );
      expect(
        resolveQualityVariantFilename(
          fileName: stagedName,
          stagingLabel: staging,
          qualityLabel: '24bit-96kHz',
          collisionOnly: true,
          cleanNameExists: true,
        ),
        'Artist - Song - 24bit-96kHz.flac',
      );
    });
  });
}
