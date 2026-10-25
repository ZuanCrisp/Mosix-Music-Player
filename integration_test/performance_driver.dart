import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Run on dedicated emulators without user data. A signing mismatch can make
/// `flutter drive` uninstall an existing app during installation, even with
/// --keep-app-running. That flag only prevents uninstalling when the run ends.
/// Use --profile on Android and macOS, and --debug on iOS simulators.
/// Keep the macOS window visible: hiding or fully covering it can suspend
/// animation clocks and frame delivery, invalidating active measurements.
/// MORNYE_PERFORMANCE_REPORT selects the host JSON output;
/// screenshots are PNGs beside that report. The aggregate target is
/// integration_test/mornye_performance_test.dart.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final output = File(
      Platform.environment['MORNYE_PERFORMANCE_REPORT'] ??
          '/tmp/mornye-performance.json',
    );
    await output.parent.create(recursive: true);
    final screenshots = data?['screenshots'];
    if (screenshots is List<dynamic>) {
      final prefix = output.path.replaceFirst(RegExp(r'\.json$'), '');
      for (final entry in screenshots) {
        final shot = entry as Map<String, dynamic>;
        final name = (shot['screenshotName'] as String).replaceAll(
          RegExp(r'[^a-zA-Z0-9_-]'),
          '_',
        );
        final bytes = (shot.remove('bytes') as List<dynamic>).cast<int>();
        final png = File('$prefix-$name.png');
        await png.writeAsBytes(bytes);
        shot.addAll({'file': png.path, 'byte_count': bytes.length});
        stdout.writeln('Screenshot: ${png.path}');
      }
    }
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
    );
    stdout.writeln('Performance report: ${output.path}');
  },
);
