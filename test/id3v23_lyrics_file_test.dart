import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/id3v23_lyrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('id3-lyrics-test-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'streams audio unchanged across insertion and replacement of lyrics',
    () async {
      final file = File('${root.path}/track.mp3');
      final chunk = Uint8List.fromList(List.generate(65536, (i) => i % 251));
      final sink = file.openWrite();
      for (var i = 0; i < 128; i++) {
        sink.add(chunk);
      }
      await sink.close();
      final audioSize = await file.length();
      final audioHash = await sha256.bind(file.openRead()).single;

      for (final lyrics in ['First lyrics', 'Replacement 歌詞']) {
        expect(
          await Id3v23Lyrics.writeUnsyncedLyricsToFile(file, lyrics),
          isTrue,
        );
        final input = await file.open();
        final header = await input.read(10);
        final tagSize =
            (header[6] << 21) |
            (header[7] << 14) |
            (header[8] << 7) |
            header[9];
        await input.setPosition(0);
        final tag = await input.read(tagSize + 10);
        await input.close();
        expect(tag, Id3v23Lyrics.writeUnsyncedLyrics(Uint8List(0), lyrics));
        expect(await file.length(), audioSize + tag.length);
        expect(await sha256.bind(file.openRead(tag.length)).single, audioHash);
        expect(await root.list().length, 1);
      }
    },
  );

  test('preserves other frames when updating an existing tag', () async {
    final file = File('${root.path}/track.mp3');
    final bytes = Id3v23Lyrics.writeUnsyncedLyrics(
      Uint8List.fromList([1, 2, 3, 4]),
      'old lyrics',
    )!;
    // Re-label the valid frame so it must be preserved alongside new USLT.
    bytes.setRange(10, 14, [0x54, 0x49, 0x54, 0x32]);
    await file.writeAsBytes(bytes);
    expect(await Id3v23Lyrics.writeUnsyncedLyricsToFile(file, 'new'), isTrue);
    expect(
      await file.readAsBytes(),
      Id3v23Lyrics.writeUnsyncedLyrics(bytes, 'new'),
    );
  });

  test(
    'unsupported, malformed and truncated tags leave the file intact',
    () async {
      for (final header in [
        [73, 68, 51, 4, 0, 0, 0, 0, 0, 0],
        [73, 68, 51, 3, 0, 0x80, 0, 0, 0, 0],
        [73, 68, 51, 3, 0, 0, 0x80, 0, 0, 0],
        [73, 68, 51, 3, 0, 0, 0, 0, 0, 100],
      ]) {
        final file = await File('${root.path}/track.mp3').writeAsBytes(header);
        expect(
          await Id3v23Lyrics.writeUnsyncedLyricsToFile(file, 'new'),
          isFalse,
        );
        expect(await file.readAsBytes(), header);
        expect(await root.list().length, 1);
      }
    },
  );
}
