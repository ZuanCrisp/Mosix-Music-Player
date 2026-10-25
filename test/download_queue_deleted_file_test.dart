import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/source_deletion_events.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this._initial);

  final DownloadQueueState _initial;

  @override
  DownloadQueueState build() {
    // Keep production subscriptions; dispose before startup performs I/O.
    super.build();
    return _initial;
  }
}

DownloadItem _item(
  String id,
  String service,
  DownloadStatus status,
  String? path,
) => DownloadItem(
  id: id,
  track: Track(
    id: '$service:song',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
    isrc: 'XX0000000001',
  ),
  service: service,
  createdAt: DateTime.utc(2026),
  status: status,
  filePath: path,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (storedPath, deletedPath) in [
    ('EXISTS:/music/song.flac', '/music/song.flac'),
    (
      'content://example.provider/tree/album/document/song.flac',
      'content://example.provider/document/song.flac',
    ),
  ]) {
    test(
      'deleted download retires while a different provider runs: $storedPath',
      () async {
        final old = _item(
          'old',
          'provider-a',
          DownloadStatus.completed,
          storedPath,
        );
        final alias = _item(
          'alias',
          'provider-a',
          DownloadStatus.completed,
          deletedPath,
        );
        final active = _item(
          'new',
          'provider-b',
          DownloadStatus.downloading,
          storedPath,
        );
        final queued = _item(
          'queued',
          'provider-c',
          DownloadStatus.queued,
          null,
        );
        final variant = _item(
          'variant',
          'provider-a',
          DownloadStatus.completed,
          '/music/song.mp3',
        );
        final unrelated = _item(
          'other',
          'provider-a',
          DownloadStatus.completed,
          '/music/other.flac',
        );
        final initial = const DownloadQueueState().copyWith(
          items: [old, alias, active, queued, variant, unrelated],
          currentDownload: active,
          isProcessing: true,
          isPaused: true,
        );
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            downloadQueueProvider.overrideWith(() => _Queue(initial)),
          ],
        );
        container.read(downloadQueueProvider);
        final publication = SourceDeletionEvents.instance.publish(deletedPath);
        try {
          final after = container.read(downloadQueueProvider);
          expect(after.items, [active, queued, variant, unrelated]);
          expect(after.lookup.byItemId.containsKey(old.id), isFalse);
          expect(after.lookup.byItemId.containsKey(alias.id), isFalse);
          expect(after.currentDownload, same(active));
          expect(after.isProcessing, isTrue);
          expect(after.isPaused, isTrue);
          expect(initial.items, hasLength(6));
        } finally {
          container.dispose();
        }
        await publication;
        // A later deletion must not call a disposed notifier.
        await SourceDeletionEvents.instance.publish('/music/song.mp3');
      },
    );
  }

  test(
    'delete then redownload creates only the new provider request',
    () async {
      final old = _item(
        'old',
        'provider-a',
        DownloadStatus.completed,
        '/music/song.flac',
      );
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(
            () => _Queue(
              const DownloadQueueState().copyWith(
                items: [old],
                currentDownload: old,
                isProcessing: true,
              ),
            ),
          ),
        ],
      );
      final queue = container.read(downloadQueueProvider.notifier);
      final publication = SourceDeletionEvents.instance.publish(old.filePath!);
      try {
        expect(container.read(downloadQueueProvider).items, isEmpty);
        expect(container.read(downloadQueueProvider).currentDownload, isNull);
        final replacement = _item(
          'replacement',
          'provider-b',
          DownloadStatus.queued,
          null,
        );
        final newId = queue.addToQueue(replacement.track, replacement.service);
        final after = container.read(downloadQueueProvider);
        expect(after.items.single.id, newId);
        expect(after.items.single.service, replacement.service);
        expect(after.items.single.track.isrc, old.track.isrc);
        expect(after.lookup.byItemId.containsKey(old.id), isFalse);
      } finally {
        container.dispose();
      }
      await publication;
    },
  );

  test(
    'unrelated and repeated deletions do not publish queue changes',
    () async {
      final item = _item(
        'kept',
        'provider-a',
        DownloadStatus.completed,
        '/music/kept.flac',
      );
      final initial = const DownloadQueueState().copyWith(items: [item]);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          downloadQueueProvider.overrideWith(() => _Queue(initial)),
        ],
      );
      var changes = 0;
      container.listen(downloadQueueProvider, (_, _) => changes++);
      final publication = SourceDeletionEvents.instance.publish(
        '/music/absent.flac',
      );
      try {
        expect(container.read(downloadQueueProvider), same(initial));
        expect(changes, 0);
      } finally {
        container.dispose();
      }
      await publication;
    },
  );
}
