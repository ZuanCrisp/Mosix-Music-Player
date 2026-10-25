import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';

class ReEnrichTestSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {}
}
