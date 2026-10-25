import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/app_crash_report.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

final appCrashProvider =
    AsyncNotifierProvider<AppCrashNotifier, AppCrashReport?>(
      AppCrashNotifier.new,
    );

final latestAppCrashProvider = FutureProvider.autoDispose<AppCrashReport?>((
  ref,
) async {
  final report = await PlatformBridge.getLatestAppCrash();
  return report == null ? null : AppCrashReport.fromMap(report);
});

class AppCrashNotifier extends AsyncNotifier<AppCrashReport?> {
  @override
  Future<AppCrashReport?> build() async {
    try {
      final report = await PlatformBridge.getPendingAppCrash();
      return report == null ? null : AppCrashReport.fromMap(report);
    } catch (error) {
      AppLogger('AppCrash').e('Could not recover crash report: $error');
      return null;
    }
  }

  Future<void> dismiss(String id) async {
    await PlatformBridge.dismissAppCrash(id);
    if (ref.mounted && state.value?.id == id) {
      state = const AsyncData(null);
    }
  }

  Future<void> markShown(String id) async {
    try {
      await PlatformBridge.markAppCrashShown(id);
    } catch (error) {
      AppLogger('AppCrash').e('Could not mark crash notice as shown: $error');
    }
  }
}
