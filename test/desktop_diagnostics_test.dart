import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/app_crash_report.dart';
import 'package:mornye/services/desktop_diagnostics.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('desktop-diagnostics-');
  });

  tearDown(() => directory.delete(recursive: true));

  Directory osReports() =>
      Directory(p.join(directory.path, 'os-reports'))
        ..createSync(recursive: true);

  DesktopDiagnostics session(int processId, {int maxLogBytes = 1 << 20}) {
    final diagnostics = DesktopDiagnostics(
      directory: directory,
      processId: processId,
      maxLogBytes: maxLogBytes,
      osCrashReportDirectory: osReports(),
    )..beginSession(device: 'test-os 1');
    addTearDown(diagnostics.close);
    return diagnostics;
  }

  LogEntry entry(String message) => LogEntry(
    timestamp: DateTime.utc(2026, 10, 20),
    level: 'ERROR',
    tag: 'Test',
    message: message,
  );

  test('a clean quit leaves nothing to report', () async {
    final first = session(1);
    expect(first.sessionMarkerExists, true);
    first.endSession();
    expect(first.sessionMarkerExists, false);
    await first.close();

    final second = session(2);
    expect(second.pendingCrash(), isNull);
    expect(second.latestCrash(), isNull);
  });

  test('a force quit without crash evidence is logged, not reported', () async {
    final first = session(1);
    first.writeEntry(entry('before the force quit'));
    await first.close();

    final second = session(2);
    expect(second.pendingCrash(), isNull);
    expect(second.latestCrash(), isNull);
    await second.close();
    expect(
      second.logFile.readAsStringSync(),
      contains('ended without quitting'),
    );
  });

  test('an OS crash report from that session becomes a report', () async {
    final first = session(1);
    await first.close();
    final executable = p.basenameWithoutExtension(Platform.resolvedExecutable);
    File(
      p.join(osReports().path, '$executable-2026-10-20-170000.ips'),
    ).writeAsStringSync('{"exception": "EXC_BAD_ACCESS"}');

    final report = session(2).pendingCrash()!;
    expect(report['reason'], 'App crash');
    expect(report['trace'], contains('EXC_BAD_ACCESS'));
  });

  test('an unclean exit after a runtime error becomes a report', () async {
    final first = session(1);
    first.writeEntry(entry('before the crash'));
    first.recordRuntimeError(error: 'StateError', stack: '#0 main', logs: '');
    await first.close();

    final second = session(2);
    final report = second.pendingCrash()!;
    expect(report['reason'], 'App error');
    expect(report['description'], 'StateError');
    expect(report['recent_logs'], contains('before the crash'));
    expect(report['runtime_error'], 'StateError');
    expect(report['device'], 'test-os 1');
    final parsed = AppCrashReport.fromMap(report);
    expect(parsed.isAnr, false);
    expect(parsed.report, contains('before the crash'));

    second.markShown(report['id'] as String);
    expect(second.pendingCrash(), isNull);
    expect(second.latestCrash(), isNotNull);
    second.dismiss(report['id'] as String);
    expect(second.latestCrash(), isNull);
  });

  test('a Rust panic from that session is the report trace', () async {
    final first = session(1);
    await first.close();
    File(
      p.join(directory.path, DesktopDiagnostics.panicLogFileName),
    ).writeAsStringSync(
      "[2026-10-20T00:00:00Z] thread 'worker' panicked at src/a.rs:1: "
      'boom\nbacktrace\n',
    );

    final report = session(2).pendingCrash()!;
    expect(report['reason'], 'Rust panic');
    expect(report['description'], contains('panicked at src/a.rs:1: boom'));
    expect(report['trace'], contains('backtrace'));
  });

  test('a hot restart in the same process is not a crash', () async {
    final first = session(7);
    await first.close();
    expect(session(7).pendingCrash(), isNull);
  });

  test('log files rotate by size', () async {
    final diagnostics = session(1, maxLogBytes: 200);
    for (var i = 0; i < 12; i++) {
      diagnostics.writeEntry(entry('line $i ${'x' * 40}'));
    }
    await diagnostics.close();
    final names =
        directory
            .listSync()
            .map((file) => p.basename(file.path))
            .where((name) => name.startsWith('mornye'))
            .toList()
          ..sort();
    expect(names, ['mornye.1.log', 'mornye.2.log', 'mornye.log']);
    expect(diagnostics.logFile.readAsStringSync(), contains('line 11'));
    expect(diagnostics.logFile.lengthSync(), lessThanOrEqualTo(200));
  });
}
