import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/extension_session_callback.dart';

void main() {
  test('parses a signed-session callback without treating state as an id', () {
    final callback = parseExtensionSessionGrantCallback(
      'mornye://session-grant?cb_version=v2grant&state=nonce_123&grant=gr_456',
    );

    expect(callback, isNotNull);
    expect(callback!.state, 'nonce_123');
    expect(callback.grant, 'gr_456');
  });

  test('extracts the expected state from a nested challenge callback', () {
    final callback = Uri(
      scheme: 'mornye',
      host: 'session-grant',
      queryParameters: const {'cb_version': 'v2grant', 'state': 'nonce_123'},
    );
    final challenge = Uri.https('api.zarz.moe', '/v2/challenge', {
      'cb': callback.toString(),
    });

    expect(extensionCallbackStateFromVerificationUri(challenge), 'nonce_123');
  });

  test('rejects callbacks without both a grant and state', () {
    expect(
      parseExtensionSessionGrantCallback('mornye://session-grant?grant=gr_456'),
      isNull,
    );
    expect(
      parseExtensionSessionGrantCallback(
        'mornye://session-grant?state=nonce_123',
      ),
      isNull,
    );
  });
}
