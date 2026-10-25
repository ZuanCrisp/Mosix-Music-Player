import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/desktop_library_watcher.dart';

LocalLibrarySource _source(
  String id,
  String path, {
  bool enabled = true,
  bool available = true,
}) => LocalLibrarySource(
  id: id,
  path: path,
  displayName: id,
  enabled: enabled,
  available: available,
);

void main() {
  late StreamController<String> changes;
  late List<List<String>> watched;
  late List<String> scans;
  late int unwatches;
  var scanning = false;

  DesktopLibraryWatcher watcher({
    Future<List<String>> Function(List<String>)? watch,
    Future<void> Function()? unwatch,
  }) => DesktopLibraryWatcher(
    scanSource: (id) async => scans.add(id),
    isScanning: () => scanning,
    watch:
        watch ??
        (paths) async {
          watched.add(paths);
          return paths;
        },
    unwatch: unwatch ?? () async => unwatches++,
    changes: changes.stream,
    debounce: const Duration(milliseconds: 60),
  );

  setUp(() {
    changes = StreamController<String>.broadcast();
    addTearDown(changes.close);
    watched = [];
    scans = [];
    unwatches = 0;
    scanning = false;
  });

  test('watches enabled, available sources once per change of set', () async {
    final subject = watcher();
    addTearDown(subject.dispose);
    await subject.updateSources([
      _source('a', '/music/a'),
      _source('b', '/music/b', enabled: false),
      _source('c', '/music/c', available: false),
    ]);
    await subject.updateSources([_source('a', '/music/a')]);
    expect(watched, [
      ['/music/a'],
    ]);
    await subject.updateSources(const []);
    expect(unwatches, 1);
  });

  test(
    'a burst of changes scans each source once after the quiet period',
    () async {
      final subject = watcher();
      addTearDown(subject.dispose);
      await subject.updateSources([
        _source('a', '/music/a'),
        _source('b', '/music/b'),
      ]);
      for (var i = 0; i < 5; i++) {
        changes.add('/music/a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      changes.add('/music/b');
      changes.add('/unknown');
      await Future<void>.delayed(Duration.zero);
      expect(scans, isEmpty);
      expect(subject.pendingSourceIds, {'a', 'b'});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(scans, ['a', 'b']);
      expect(subject.pendingSourceIds, isEmpty);
    },
  );

  test('a running scan postpones the rescan instead of dropping it', () async {
    final subject = watcher();
    addTearDown(subject.dispose);
    await subject.updateSources([_source('a', '/music/a')]);
    scanning = true;
    changes.add('/music/a');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(scans, isEmpty);
    scanning = false;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(scans, ['a']);
  });

  test('dispose cancels pending scans and stops watching', () async {
    final subject = watcher();
    await subject.updateSources([_source('a', '/music/a')]);
    changes.add('/music/a');
    await Future<void>.delayed(Duration.zero);
    await subject.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(scans, isEmpty);
    expect(unwatches, 1);
  });

  test('a failed registration can retry an unchanged source set', () async {
    var attempts = 0;
    final subject = watcher(
      watch: (paths) async {
        if (++attempts == 1) throw StateError('temporarily unavailable');
        watched.add(paths);
        return paths;
      },
    );
    addTearDown(subject.dispose);
    await subject.updateSources([_source('a', '/music/a')]);
    await subject.updateSources([_source('a', '/music/a')]);
    expect(attempts, 2);
    expect(watched, [
      ['/music/a'],
    ]);
  });

  test('registration changes stay ordered and skip superseded roots', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final subject = watcher(
      watch: (paths) async {
        watched.add(paths);
        if (paths.single == '/music/a') {
          started.complete();
          await release.future;
        }
        return paths;
      },
    );
    addTearDown(subject.dispose);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final first = subject.updateSources([_source('a', '/music/a')]);
    await started.future;
    final superseded = subject.updateSources([_source('b', '/music/b')]);
    final latest = subject.updateSources([_source('c', '/music/c')]);
    await Future<void>.delayed(Duration.zero);
    expect(watched, [
      ['/music/a'],
    ]);
    release.complete();
    await Future.wait([first, superseded, latest]);
    expect(watched, [
      ['/music/a'],
      ['/music/c'],
    ]);
  });

  test(
    'replacement registration waits for the disposed native watch',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      final previous = watcher(
        watch: (paths) async {
          events.add('old watch');
          started.complete();
          await release.future;
          return paths;
        },
        unwatch: () async => events.add('old stop'),
      );
      final registration = previous.updateSources([_source('a', '/music/a')]);
      await started.future;
      final disposed = previous.dispose();
      final replacement = watcher(
        watch: (paths) async {
          events.add('new watch');
          return paths;
        },
      );
      addTearDown(replacement.dispose);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final replaced = replacement.updateSources([_source('b', '/music/b')]);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['old watch']);
      release.complete();
      await Future.wait([registration, disposed, replaced]);
      expect(events, ['old watch', 'old stop', 'new watch']);
      await previous.dispose();
      expect(events, ['old watch', 'old stop', 'new watch']);
    },
  );

  test('empty sources stop a partially failed registration', () async {
    final subject = watcher(
      watch: (_) async => throw StateError('registration failed'),
    );
    addTearDown(subject.dispose);
    await subject.updateSources([_source('a', '/music/a')]);
    await subject.updateSources(const []);
    expect(unwatches, 1);
    await subject.dispose();
    expect(unwatches, 1);
  });

  test('an event stream error does not abort later rescans', () async {
    final subject = watcher();
    addTearDown(subject.dispose);
    await subject.updateSources([_source('a', '/music/a')]);
    changes.addError(StateError('temporary stream error'));
    changes.add('/music/a');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(scans, ['a']);
  });
}
