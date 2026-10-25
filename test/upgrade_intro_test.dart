import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/theme_settings.dart';
import 'package:mosix/providers/theme_provider.dart';
import 'package:mosix/screens/upgrade_intro_screen.dart';
import 'package:mosix/services/upgrade_intro_service.dart';
import 'package:mosix/theme/app_theme.dart';
import 'package:mosix/theme/mornye_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'Google Sans Flex',
    )..addFont(rootBundle.load('assets/fonts/GoogleSansFlex.ttf'))).load();
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
  });

  test(
    'upgrade tour is acknowledged separately from settings migrations',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings_migration_version': 11,
      });
      var prefs = await SharedPreferences.getInstance();
      bool pending(String version, {bool existing = true}) =>
          UpgradeIntroService.shouldShow(
            prefs,
            version: version,
            existingInstallation: existing,
          );
      expect(pending('5.0.0'), isTrue);
      expect(pending('5.0.1'), isTrue);
      expect(pending('4.9.0'), isFalse);
      expect(pending('6.0.0'), isFalse);
      expect(pending('5.0.0', existing: false), isFalse);
      await UpgradeIntroService.markSeen(prefs);
      prefs = await SharedPreferences.getInstance();
      expect(pending('5.0.0'), isFalse);
      expect(prefs.getInt('settings_migration_version'), 11);
    },
  );

  final capture = GlobalKey();
  Future<void> openTour(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    Brightness brightness = Brightness.light,
    AppThemeStyle style = AppThemeStyle.mornye,
  }) async {
    SharedPreferences.setMockInitialValues({kThemeStyleKey: style.name});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialThemeSettingsProvider.overrideWithValue(
            ThemeSettings(style: style),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            final selectedStyle = ref.watch(
              themeProvider.select((value) => value.style),
            );
            return MaterialApp(
              theme: selectedStyle == AppThemeStyle.mornye
                  ? MornyeTheme.build(brightness)
                  : brightness == Brightness.dark
                  ? AppTheme.dark()
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: RepaintBoundary(key: capture, child: child),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const UpgradeIntroScreen(),
                      ),
                    ),
                    child: const Text('Open tour'),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Open tour'));
    await tester.pumpAndSettle();
  }

  Future<void> capturePage(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_UPGRADE_INTRO')) return;
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '/tmp/spotiflac-intro-$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('tour advances, goes back and finishes ($brightness)', (
      tester,
    ) async {
      await openTour(tester, brightness: brightness);
      expect(find.text('Welcome to\nMosix 1.0'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await capturePage(tester, '${brightness.name}-welcome');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Make it\nyour own.'), findsOneWidget);
      await capturePage(tester, '${brightness.name}-themes');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Welcome to\nMosix 1.0'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        if (i == 1) {
          expect(find.text('Get to know\nyour Library.'), findsOneWidget);
          await capturePage(tester, '${brightness.name}-library');
        }
        if (i == 2) {
          expect(find.text('A new engine.\nBuilt with Rust.'), findsOneWidget);
          await capturePage(tester, '${brightness.name}-rust');
        }
      }
      await capturePage(tester, '${brightness.name}-player');
      await tester.tap(find.text('Start listening'));
      await tester.pumpAndSettle();
      expect(find.byType(UpgradeIntroScreen), findsNothing);
      expect(find.text('Open tour'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('theme choice applies live, persists and updates the guide', (
    tester,
  ) async {
    await openTour(tester, style: AppThemeStyle.material);
    await capturePage(tester, 'material-welcome');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kThemeStyleKey), 'material');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    final mornye = find.byKey(const ValueKey('intro-theme-mornye'));
    await tester.ensureVisible(mornye);
    await tester.tap(mornye);
    await tester.pumpAndSettle();
    expect(prefs.getString(kThemeStyleKey), 'mornye');
    expect(tester.element(find.byType(UpgradeIntroScreen)).isMornye, isTrue);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Recently Added.'), findsWidgets);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    final material = find.byKey(const ValueKey('intro-theme-material'));
    await tester.ensureVisible(material);
    await tester.tap(material);
    await tester.pumpAndSettle();
    expect(prefs.getString(kThemeStyleKey), 'material');
    expect(tester.element(find.byType(UpgradeIntroScreen)).isMornye, isFalse);
    await capturePage(tester, 'material-themes');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('A new engine.\nBuilt with Rust.'), findsOneWidget);
    expect(find.text('Get to know\nyour Library.'), findsNothing);
    expect(find.text('Set up\nyour player.'), findsNothing);
    expect(find.bySemanticsLabel('3 / 3'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
    await capturePage(tester, 'material-rust');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Make it\nyour own.'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('A new engine.\nBuilt with Rust.'), findsOneWidget);
    await tester.tap(find.text('Start listening'));
    await tester.pumpAndSettle();
    expect(prefs.getString(kThemeStyleKey), 'material');
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets(
      'tour scrolls with large text and can skip from any page ($size)',
      (tester) async {
        await openTour(tester, size: size, textScale: 2);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byType(SingleChildScrollView).first,
          const Offset(0, -400),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Skip'));
        await tester.pumpAndSettle();
        expect(find.byType(UpgradeIntroScreen), findsNothing);
      },
    );
  }
}
