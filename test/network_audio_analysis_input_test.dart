import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';
import 'package:mornye/services/network_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory temporary;
  late HttpServer server;
  late NetworkStorageService storage;
  late NetworkAudioAnalysisInput input;
  final requests = <String>[];
  const name = 'हिन्दी & Rock + #1.wav';
  final audio = List<int>.generate(128 * 1024, (i) => i % 256);
  var status = HttpStatus.ok;
  var empty = false;
  Completer<void>? release;
  Completer<void>? started;

  setUp(() async {
    requests.clear();
    status = HttpStatus.ok;
    empty = false;
    release = null;
    started = null;
    temporary = await Directory.systemTemp.createTemp('network-analysis-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        requests.add(request.method);
        expect(request.uri.pathSegments.last, name);
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Basic ${base64Encode(utf8.encode('tester:secret'))}',
        );
        request.response.statusCode = status;
        if (status != HttpStatus.ok) return;
        request.response.contentLength = empty ? 0 : audio.length;
        if (request.method == 'GET' && !empty) {
          request.response.add(audio.sublist(0, 1024));
          await request.response.flush();
          started?.complete();
          if (release != null) await release!.future;
          request.response.add(audio.sublist(1024));
        }
      } finally {
        try {
          await request.response.close();
        } on IOException {
          // Cancellation intentionally closes the client mid-transfer.
        }
      }
    });
    storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    await storage.save(
      NetworkConnection(
        id: 'fixture',
        name: 'Fixture',
        protocol: NetworkProtocol.webdav,
        address: 'http://127.0.0.1:${server.port}/music/',
        username: 'tester',
        password: 'secret',
      ),
    );
    input = NetworkAudioAnalysisInput(
      storage: storage,
      temporaryDirectory: () async => temporary,
    );
  });

  tearDown(() async {
    if (release != null && !release!.isCompleted) release!.complete();
    input.cancel();
    await storage.dispose();
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });

  String source() => NetworkStorageService.source('fixture', name);

  test('authenticated staging preserves bytes and is read-only', () async {
    expect(await input.length(source()), audio.length);
    String? stagedPath;
    final result = await input.withFile(source(), (path) async {
      stagedPath = path;
      expect(path.endsWith('.wav'), true);
      expect(await File(path).readAsBytes(), audio);
      // Native analysis may reopen/seek the input more than once.
      final handle = await File(path).open();
      try {
        await handle.setPosition(1234);
        expect(await handle.read(10), audio.sublist(1234, 1244));
      } finally {
        await handle.close();
      }
      return 'analysed';
    });
    expect(result, 'analysed');
    expect(await File(stagedPath!).exists(), false);
    expect(await temporary.list().toList(), isEmpty);
    expect(requests, ['HEAD', 'GET']);
  });

  test('Hi-Res checker receives the staged file, never a proxy URL', () async {
    const channel = MethodChannel('com.zarz.mornye/backend');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'checkHiResAuthenticity');
          final path = (call.arguments as Map)['file_path'] as String;
          expect(await File(path).readAsBytes(), audio);
          return {'supported': true, 'declared_sample_rate': 96000};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final result = await HiResCheckService.check(source(), networkInput: input);
    expect(result.supported, true);
    expect(result.declaredSampleRate, 96000);
    expect(await temporary.list().toList(), isEmpty);
  });

  test('decoder errors clean up the input', () async {
    await expectLater(
      input.withFile<void>(source(), (_) async => throw StateError('decoder')),
      throwsStateError,
    );
    expect(await temporary.list().toList(), isEmpty);
  });

  test('server errors and empty audio never run a decoder', () async {
    var decoded = false;
    for (final code in [404, 401, 500, 206, 200]) {
      status = code;
      empty = true;
      await expectLater(
        input.withFile<void>(source(), (_) async => decoded = true),
        throwsA(isA<HttpException>()),
      );
      expect(decoded, false);
      expect(await temporary.list().toList(), isEmpty);
    }
  });

  test('cancelling a transfer leaves another analyser usable', () async {
    release = Completer<void>();
    started = Completer<void>();
    var decoded = false;
    final transfer = input.withFile<void>(
      source(),
      (_) async => decoded = true,
    );
    final cancelled = expectLater(
      transfer,
      throwsA(isA<AudioAnalysisCancelled>()),
    );
    await started!.future;
    input.cancel();
    await cancelled.timeout(const Duration(seconds: 2));
    expect(decoded, false);
    expect(await temporary.list().toList(), isEmpty);
    release!.complete();
    release = null;
    started = null;
    final other = NetworkAudioAnalysisInput(
      storage: storage,
      temporaryDirectory: () async => temporary,
    );
    expect(await other.length(source()), audio.length);
    expect(await input.withFile(source(), (_) async => 7), 7);
  });

  test(
    'cancel waits for an active decoder before deleting its input',
    () async {
      final entered = Completer<void>();
      final completed = Completer<void>();
      String? stagedPath;
      final task = input.withFile<void>(source(), (path) async {
        stagedPath = path;
        entered.complete();
        await completed.future;
        expect(await File(path).exists(), true);
      });
      final cancelled = expectLater(
        task,
        throwsA(isA<AudioAnalysisCancelled>()),
      );
      await entered.future;
      input.cancel();
      expect(await File(stagedPath!).exists(), true);
      completed.complete();
      await cancelled;
      expect(await temporary.list().toList(), isEmpty);
    },
  );

  test('a stalled stream times out and removes partial audio', () async {
    release = Completer<void>();
    started = Completer<void>();
    final bounded = NetworkAudioAnalysisInput(
      storage: storage,
      temporaryDirectory: () async => temporary,
      timeout: const Duration(milliseconds: 100),
    );
    var decoded = false;
    await expectLater(
      bounded.withFile<void>(source(), (_) async => decoded = true),
      throwsA(isA<TimeoutException>()),
    );
    expect(decoded, false);
    expect(await temporary.list().toList(), isEmpty);
  });
}
