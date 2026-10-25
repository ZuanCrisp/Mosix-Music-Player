import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/network_storage_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const address = String.fromEnvironment('SMB_TEST_URL');
  testWidgets('native SMB3 lists and serves a seek range on device', (
    tester,
  ) async {
    final storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    const connection = NetworkConnection(
      id: 'fixture',
      name: 'Fixture',
      protocol: NetworkProtocol.smb,
      address: address,
      username: 'test',
      password: 'secret',
    );
    final client = HttpClient();
    try {
      await storage.save(connection);
      expect(
        (await storage.list(connection)).any((e) => e.name == 'A B.wav'),
        true,
      );
      final uri = await storage.resolve(
        NetworkStorageService.source('fixture', 'A B.wav'),
      );
      final request = await client.getUrl(Uri.parse(uri));
      request.headers.set('Range', 'bytes=100-103');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(await response.expand((e) => e).toList(), [100, 101, 102, 103]);
    } finally {
      client.close(force: true);
      await storage.dispose();
    }
  }, skip: address.isEmpty);
}
