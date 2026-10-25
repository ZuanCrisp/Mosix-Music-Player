import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/utils/extension_session_callback.dart';

void main() {
  test('parses a signed-session callback without treating state as an id', () {
    final callback = parseExtensionSessionGrantCallback(
      'spotiflac://session-grant?cb_version=v2grant&state=nonce_123&grant=gr_456',
    );

    expect(callback, isNotNull);
    expect(callback!.state, 'nonce_123');
    expect(callback.grant, 'gr_456');
  });

  test('extracts the expected state from a nested challenge callback', () {
    final callback = Uri(
      scheme: 'spotiflac',
      host: 'session-grant',
      queryParameters: const {'cb_version': 'v2grant', 'state': 'nonce_123'},
    );
    final challenge = Uri.https('auth.example.test', '/v2/challenge', {
      'cb': callback.toString(),
    });

    expect(extensionCallbackStateFromVerificationUri(challenge), 'nonce_123');
  });

  test('rejects callbacks without both a grant and state', () {
    expect(
      parseExtensionSessionGrantCallback(
        'spotiflac://session-grant?grant=gr_456',
      ),
      isNull,
    );
    expect(
      parseExtensionSessionGrantCallback(
        'spotiflac://session-grant?state=nonce_123',
      ),
      isNull,
    );
  });
}
