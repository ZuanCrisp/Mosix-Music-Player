import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/lyrics_parser.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final cases = <String, (String, bool, bool)>{
    'zero provider placeholders': (
      '[by:Example app (source: extension:example)]\n'
          '[00:00.00]First line\n[00:00.00]Second line',
      false,
      false,
    ),
    'zero word placeholders with offset': (
      '[offset:-500]\n'
          '[00:00.00]<00:00.00>First <00:00.00>line<00:00.00>',
      false,
      false,
    ),
    'empty positive outro': (
      '[00:00.00]First line\n[00:00.00]Second line\n[01:00.00]',
      false,
      false,
    ),
    'zero TTML intervals': (
      '<tt><body><p begin="0s" end="0s">First line</p>'
          '<p begin="0s" end="0s">Second line</p></body></tt>',
      false,
      false,
    ),
    'real line timing starting at zero': (
      '[00:00.00]First line\n[00:02.00]Second line',
      true,
      false,
    ),
    'real word timing starting at zero': (
      '[00:00.00]<00:00.00>First <00:01.00>line<00:02.00>',
      true,
      true,
    ),
    'real TTML duration starting at zero': (
      '<tt><body><p begin="0s" end="2s">First line</p></body></tt>',
      true,
      false,
    ),
    'valid timing clamped by offset': (
      '[offset:5000]\n[00:00.00]First line\n[00:02.00]Second line',
      true,
      false,
    ),
  };

  for (final entry in cases.entries) {
    testWidgets('actual native parser: ${entry.key}', (tester) async {
      final (raw, synced, wordSynced) = entry.value;
      // Call the real worker directly: missing/stale bindings must fail here.
      final native = await PlatformBridge.runNativeDataJob({
        'operation': 'parse_lyrics',
      }, bytes: Uint8List.fromList(utf8.encode(raw)));
      expect(native['synced'], synced);
      expect(native['wordSynced'], wordSynced);
      final parsed = await LyricsParser.parseAsyncNative(raw);
      final fallback = LyricsParser.parse(raw);
      expect(parsed.synced, synced);
      expect(parsed.wordSynced, wordSynced);
      expect(parsed.plainText, fallback.plainText);
      expect(parsed.provider, fallback.provider);
      expect(parsed.lines.length, fallback.lines.length);
      if (!synced) {
        expect(parsed.lines, isEmpty);
        expect(parsed.plainText, contains('First line'));
        expect(parsed.plainText, isNot(contains('00:00')));
      }
    });
  }
}
