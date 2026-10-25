import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/preview_player_provider.dart';
import 'package:mosix/services/music_player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer previews(MusicPlayerRuntime runtime) => ProviderContainer(
    overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
  );

  test('preview ownership stays within its playback runtime', () async {
    final firstRuntime = MusicPlayerRuntime();
    final secondRuntime = MusicPlayerRuntime();
    final first = previews(firstRuntime);
    final second = previews(secondRuntime);
    first.read(previewPlayerProvider);
    second.read(previewPlayerProvider);
    final secondHook = secondRuntime.exclusiveAudioHook;

    expect(firstRuntime.exclusiveAudioHook, isNotNull);
    expect(secondHook, isNotNull);
    expect(firstRuntime.exclusiveAudioHook, isNot(same(secondHook)));
    first.dispose();
    expect(firstRuntime.exclusiveAudioHook, isNull);
    expect(secondRuntime.exclusiveAudioHook, same(secondHook));
    second.dispose();
    expect(secondRuntime.exclusiveAudioHook, isNull);
    await firstRuntime.dispose();
    await secondRuntime.dispose();
  });

  test('disposing an old preview preserves the new audio owner', () async {
    final runtime = MusicPlayerRuntime();
    final first = previews(runtime);
    final second = previews(runtime);
    first.read(previewPlayerProvider);
    final firstHook = runtime.exclusiveAudioHook;
    second.read(previewPlayerProvider);
    final secondHook = runtime.exclusiveAudioHook;

    expect(firstHook, isNot(same(secondHook)));
    first.dispose();
    expect(runtime.exclusiveAudioHook, same(secondHook));
    second.dispose();
    expect(runtime.exclusiveAudioHook, isNull);
    await runtime.dispose();
  });
}
