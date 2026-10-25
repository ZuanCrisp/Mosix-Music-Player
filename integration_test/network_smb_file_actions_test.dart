import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/file_access.dart';

// Run scripts/smb2_fixture_server.py --deletion first. Only fixture files
// are deleted; Android emulators use 10.0.2.2 instead of 127.0.0.1.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const address = String.fromEnvironment('TEST_SMB_ADDRESS');
  test(
    'native SMB removes the selected file and preserves its siblings',
    () async {
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      addTearDown(storage.dispose);
      final connection = NetworkConnection(
        id: 'fixture',
        name: 'Fixture NAS',
        protocol: NetworkProtocol.smb,
        address: address,
        username: 'test',
        password: 'secret',
      );
      await storage.save(connection);
      expect(await storage.deleteFile('network://fixture/Deletion'), isFalse);
      expect(
        await deleteFile(
          'network://fixture/Deletion/Target.flac',
          networkStorage: storage,
        ),
        isTrue,
      );
      expect(
        (await storage.list(
          connection,
          'Deletion/',
        )).map((entry) => entry.name),
        ['Keep.flac'],
      );
    },
    skip: address.isEmpty,
  );
}
