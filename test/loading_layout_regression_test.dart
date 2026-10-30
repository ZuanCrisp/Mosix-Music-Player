import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/repo_provider.dart';
import 'package:mosix/screens/repo_tab.dart';
import 'package:mosix/theme/app_theme.dart';
import 'package:mosix/theme/mosix_theme.dart';
import 'package:mosix/widgets/animation_utils.dart';
import 'package:mosix/widgets/extension_row.dart';

class _LoadingRepo extends RepoNotifier {
  @override
  RepoState build() => const RepoState(
    isLoading: true,
    isInitialized: true,
    registryUrl: 'https://example.invalid/registry.json',
  );

  @override
  Future<void> initialize(String cacheDir) async {}
}

void main() {
  for (final width in [320.0, 1024.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('Material loading rows fit at $width in $brightness', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        for (final skeleton in const [
          TrackListSkeleton(itemCount: 3),
          AlbumTrackListSkeleton(itemCount: 3),
          HomeSearchSkeleton(),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.light
                  ? AppTheme.light()
                  : AppTheme.dark(),
              home: Scaffold(body: skeleton),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    for (final mosix in [false, true]) {
      testWidgets('store skeleton fits at $width with Mosix=$mosix', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          paths,
          (_) async => '/tmp/mosix-loading-test',
        );
        addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [repoProvider.overrideWith(_LoadingRepo.new)],
            child: MaterialApp(
              theme: mosix
                  ? MosixTheme.build(Brightness.dark)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const RepoTab(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(ExtensionRow), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
