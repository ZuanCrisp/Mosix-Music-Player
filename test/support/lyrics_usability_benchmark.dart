final _timestamp = RegExp(r'^\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]');
final _metadata = RegExp(r'^\[[a-zA-Z][a-zA-Z0-9_-]*:.*\]$');
final _inlineTimestamp = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');
final _speaker = RegExp(r'^v[1-9]\d*:\s*', caseSensitive: false);
final _background = RegExp(r'^\[bg:(.*)\]$', caseSensitive: false);

// Frozen display normalization before the short-circuit optimization. This is
// also the independent oracle for display and boolean differential tests.
String legacyCleanLyricsForDisplay(String lyrics) {
  final cleanLines = <String>[];
  for (final line in lyrics.split('\n')) {
    var cleaned = line.trim();
    if (_metadata.hasMatch(cleaned) && !_background.hasMatch(cleaned)) continue;
    final background = _background.firstMatch(cleaned);
    if (background != null) cleaned = background.group(1)?.trim() ?? '';
    while (_timestamp.hasMatch(cleaned)) {
      cleaned = cleaned.replaceFirst(_timestamp, '').trim();
    }
    cleaned = cleaned.replaceAll(_inlineTimestamp, '').trim();
    cleaned = cleaned.replaceFirst(_speaker, '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isNotEmpty) cleanLines.add(cleaned);
  }
  return cleanLines.join('\n');
}

String lyricsUsabilityFixture(int lines, {bool metadataOnly = false}) => [
  '[ti:Example song]',
  '[ar:Example artist]',
  for (var index = 0; index < lines; index++)
    metadataOnly
        ? '[comment:Metadata $index]'
        : '[00:${(index % 60).toString().padLeft(2, '0')}.00]<00:01.00>v2: Line $index — 音楽 🎵',
].join('\n');

// The previous usability path normalized and joined the complete display text.
bool fullDisplayLyricsUsability(String lyrics) =>
    lyrics.trim().toLowerCase() == '[instrumental:true]' ||
    legacyCleanLyricsForDisplay(lyrics).trim().isNotEmpty;

Map<String, int> measureLyricsUsability(
  bool Function(String) check,
  String lyrics, {
  int repetitions = 1000,
}) {
  var usable = 0;
  final watch = Stopwatch()..start();
  for (var index = 0; index < repetitions; index++) {
    if (check(lyrics)) usable++;
  }
  watch.stop();
  return {'microseconds': watch.elapsedMicroseconds, 'usable': usable};
}
