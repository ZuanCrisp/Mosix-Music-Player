import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/app_localizations.dart';
import 'package:mosix/services/app_navigation_service.dart';
import 'package:mosix/utils/extension_auth_launcher.dart';

void main() {
  const channel = MethodChannel('com.zuancrisp.mosix/backend');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> showApp(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: AppNavigationService.rootNavigatorKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: Text('Library')),
    ),
  );

  testWidgets('missing pending challenge explains why no page opened', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getExtensionPendingAuth');
          return null;
        });
    await showApp(tester);
    expect(await openPendingExtensionVerification('provider-a'), isFalse);
    await tester.pump();
    expect(
      find.text(
        'No verification page is available for provider-a. '
        'Retry the download to request a new challenge.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelled pending lookup does not show a failure message', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    final cancellation = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => pending.future);
    await showApp(tester);
    final result = openPendingExtensionVerification(
      'provider-a',
      cancellationSignal: cancellation.future,
    );
    cancellation.complete();
    expect(await result, isFalse);
    pending.complete();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
