import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/discord_presence_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop channel maps the plugin contract to backend methods', () async {
    final calls = <String>[];
    final arguments = <Object?>[];
    final statuses = StreamController<String>.broadcast();
    addTearDown(statuses.close);
    final channel = DesktopDiscordChannel(
      invoke: (method, argument) async {
        calls.add(method);
        arguments.add(argument);
        return method == 'discordPresenceInitialize' ? true : null;
      },
      statuses: statuses.stream,
    );
    expect(await channel.invokeMethod<bool>('initialize'), true);
    await channel.invokeMethod<void>('update', {'title': 'Song'});
    await channel.invokeMethod<void>('clear');
    await channel.invokeMethod<void>('shutdown');
    expect(calls, [
      'discordPresenceInitialize',
      'discordPresenceUpdate',
      'discordPresenceClear',
      'discordPresenceShutdown',
    ]);
    expect(arguments, [
      null,
      {'title': 'Song'},
      null,
      null,
    ]);
    await expectLater(
      channel.invokeMethod<void>('authorize'),
      throwsA(isA<MissingPluginException>()),
    );

    final received = <MethodCall>[];
    channel.setMethodCallHandler((call) async => received.add(call));
    statuses.add('active');
    await pumpEventQueue();
    expect(received.single.method, 'status');
    expect(received.single.arguments, 'active');
    channel.setMethodCallHandler(null);
    statuses.add('unavailable');
    await pumpEventQueue();
    expect(received, hasLength(1));
  });

  testWidgets('the service runs on the desktop channel without a link', (
    tester,
  ) async {
    final methods = <String>[];
    final statuses = StreamController<String>.broadcast();
    addTearDown(statuses.close);
    final service = DiscordPresenceService(
      channel: DesktopDiscordChannel(
        invoke: (method, _) async {
          methods.add(method);
          return method == 'discordPresenceInitialize' ? true : null;
        },
        statuses: statuses.stream,
      ),
      requiresLink: false,
      resolveArtwork: (_) async => null,
      now: tester.binding.clock.now,
    );
    final player = BaseAudioHandler();
    service.bind(player);
    player.mediaItem.add(
      const MediaItem(id: 'id', title: 'Song', artist: 'Artist'),
    );
    player.playbackState.add(
      PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        updateTime: tester.binding.clock.now(),
      ),
    );
    await service.setEnabled(true);
    await tester.pump();
    expect(methods, ['discordPresenceInitialize', 'discordPresenceUpdate']);
    statuses.add('active');
    await tester.pump();
    expect(service.status.value, DiscordPresenceStatus.active);
    statuses.add('unavailable');
    await tester.pump();
    expect(service.status.value, DiscordPresenceStatus.unavailable);
    await tester.runAsync(service.dispose);
    expect(methods.last, 'discordPresenceShutdown');
  });
}
