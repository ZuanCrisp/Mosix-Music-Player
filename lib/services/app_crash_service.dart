import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

/// Saves context for a later confirmed process crash. A handled Flutter error
/// alone must not produce a misleading "app crashed" message on the next launch.
class AppCrashService {
  static Future<void> recordRuntimeError(
    Object error,
    StackTrace? stack,
  ) async {
    try {
      final entries = LogBuffer().entries;
      await PlatformBridge.recordAppRuntimeError(
        error: redactDiagnosticText(error.toString()),
        stack: redactDiagnosticText(stack?.toString() ?? ''),
        logs: formatLogEntries(
          entries.skip(entries.length > 40 ? entries.length - 40 : 0),
        ),
      );
    } catch (_) {
      // Never route a reporting failure back into the global error handler.
    }
  }
}
