import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

Future<Map<String, dynamic>> callTestVmService(
  Uri service,
  String method, [
  Map<String, String> parameters = const {},
]) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      service.resolve(method).replace(queryParameters: parameters),
    );
    final response = await request.close();
    final decoded =
        jsonDecode(await response.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    if (decoded['error'] != null) {
      throw StateError('VM service failed: ${decoded['error']}');
    }
    return decoded['result'] as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<void> collectTestGarbage(Uri service) async {
  await callTestVmService(service, 'getAllocationProfile', {
    'isolateId': developer.Service.getIsolateId(Isolate.current)!,
    'gc': 'true',
  });
}
