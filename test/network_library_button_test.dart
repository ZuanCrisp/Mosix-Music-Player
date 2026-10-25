import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/local_library_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/screens/network_storage_screen.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/services/network_storage_service.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/widgets/app_action_button.dart';

class _Storage extends NetworkStorageService {
  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection c, [
    String path = '',
  ]) async => [];
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(localLibraryEnabled: false);
  @override
  void setLocalLibraryEnabled(bool enabled) =>
      state = state.copyWith(localLibraryEnabled: enabled);
}

class _Library extends LocalLibraryNotifier {
  _Library(this._events);
  final List<String> _events;
  @override
  LocalLibraryState build() => LocalLibraryState();
  @override
  Future<LocalLibrarySource> addSource({
    required String path,
    required String displayName,
    String? bookmark,
    String? volumeId,
    bool isRemovable = false,
  }) async {
    _events.add(path);
    final source = LocalLibrarySource(
      id: 'nas-folder',
      path: path,
      displayName: displayName,
    );
    state = state.copyWith(sources: [source]);
    return source;
  }

  @override
  Future<void> startSourceScan(
    String sourceId, {
    bool forceFullScan = false,
  }) async {
    _events.add('scan:$sourceId');
  }
}

void main() {
  for (final mornye in [false, true]) {
    for (final protocol in [NetworkProtocol.smb, NetworkProtocol.webdav]) {
      testWidgets(
        'adds selected folder and starts Library scan ($mornye, $protocol)',
        (tester) async {
          final events = <String>[];
          final connection = NetworkConnection(
            id: 'nas',
            name: 'Home NAS',
            protocol: protocol,
            address: protocol == NetworkProtocol.smb
                ? 'smb://nas/Music/'
                : 'https://nas/Music/',
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                localLibraryProvider.overrideWith(() => _Library(events)),
                settingsProvider.overrideWith(_Settings.new),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MosixTheme.build(Brightness.dark)
                    : ThemeData(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: NetworkStorageScreen(
                  connection: connection,
                  path: 'Albums/',
                  service: _Storage(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(AppActionButton, 'Add folder to Library'),
          );
          await tester.pumpAndSettle();
          expect(events, ['network://nas/Albums/', 'scan:nas-folder']);
          expect(find.text('Folder added to Library'), findsOneWidget);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(NetworkStorageScreen)),
          );
          expect(container.read(settingsProvider).localLibraryEnabled, true);
          expect(
            container.read(localLibraryProvider).sources.single.displayName,
            'Home NAS / Albums',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
