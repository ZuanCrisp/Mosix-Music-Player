import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native Discord SDK can initialize, stop, and restart', (
    tester,
  ) async {
    const channel = MethodChannel('com.zarz.mornye/discord');
    // Staging the official SDK is a prerequisite for this device-only test.
    // No account is linked and no listening activity is published.
    for (var i = 0; i < 2; i++) {
      try {
        expect(await channel.invokeMethod<bool>('initialize'), isTrue);
        await tester.pump(const Duration(milliseconds: 350));
        await channel.invokeMethod<void>('clear');
      } finally {
        await channel.invokeMethod<void>('shutdown');
      }
    }
  });
}
