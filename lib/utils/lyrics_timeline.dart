import 'package:mosix/utils/lyrics_parser.dart';

/// Visual order is separate from the chronological timeline: a backing part
/// stays directly under its lead, including when another singer starts first.
class LyricDisplayLayout {
  final List<int> lineOrder;
  final List<int> rowForLine;
  final List<int> leadForLine;
  final List<int> focusForLine;

  LyricDisplayLayout(List<LyricLine> lines)
    : lineOrder = [],
      rowForLine = List.filled(lines.length, 0),
      leadForLine = List.generate(lines.length, (index) => index),
      focusForLine = List.filled(lines.length, 0) {
    final leads = {
      for (var i = 0; i < lines.length; i++)
        if (!lines[i].isBackground && lines[i].vocalGroup != null)
          lines[i].vocalGroup!: i,
    };
    final backing = <int, List<int>>{};
    int? previousLead;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.isBackground) {
        if (line.text.isNotEmpty) previousLead = i;
        continue;
      }
      final lead = line.vocalGroup == null
          ? previousLead
          : leads[line.vocalGroup];
      if (lead == null) continue;
      leadForLine[i] = lead;
      backing.putIfAbsent(lead, () => []).add(i);
    }
    for (var i = 0; i < lines.length; i++) {
      if (leadForLine[i] != i) continue;
      lineOrder.add(i);
      lineOrder.addAll(backing[i] ?? const []);
    }
    for (var row = 0; row < lineOrder.length; row++) {
      rowForLine[lineOrder[row]] = row;
    }
    var latestLead = 0;
    Duration? latestLeadStart;
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].isBackground && lines[i].time != latestLeadStart) {
        latestLead = i;
        latestLeadStart = lines[i].time;
      }
      // Simultaneous leads share the first row as their scroll anchor, so the
      // earlier singer cannot be pushed above the viewport while still singing.
      // A delayed echo must not scroll backwards after the next lead starts.
      focusForLine[i] = lines[i].isBackground && leadForLine[i] > latestLead
          ? leadForLine[i]
          : latestLead;
    }
  }
}

/// Hold the latest lead until the next lead starts, including instrumental
/// gaps. Earlier overlapping parts and backing vocals keep their timed ends.
Set<int> activeLyricIndices(
  List<LyricLine> lines,
  Duration position,
  int currentIndex,
) {
  final active = <int>{};
  var heldLead = -1;
  for (var i = 0; i <= currentIndex; i++) {
    final line = lines[i];
    if (!line.isBackground &&
        line.text.isNotEmpty &&
        (heldLead < 0 || line.time != lines[heldLead].time)) {
      // Simultaneous singers retain their shared first-row focus.
      heldLead = i;
    }
    final timedVoice =
        (i < currentIndex || line.voice != null || line.isBackground) &&
        line.text.isNotEmpty &&
        line.end != null;
    // Secondary simultaneous singers and backing parts keep their own ends.
    final simultaneous =
        line.text.isNotEmpty && line.time == lines[currentIndex].time;
    if (timedVoice ? line.end! > position : i == currentIndex || simultaneous) {
      active.add(i);
    }
  }
  if (heldLead >= 0) active.add(heldLead);
  return active;
}

/// Inserts empty, bounded rows for instrumental countdowns in the player.
/// Unmarked gaps in plain LRC cannot be distinguished from held vocals: only
/// use explicit empty timestamps or known line/word ends, never an estimate.
List<LyricLine> lyricsTimelineWithGaps(List<LyricLine> lines) {
  const minimumGap = Duration(seconds: 3);
  final timeline = <LyricLine>[];
  Duration? gapStart;
  Duration? latestVocalEnd;

  for (final line in lines) {
    if (line.text.trim().isEmpty) {
      gapStart ??= line.time;
      continue;
    }

    var start = timeline.isEmpty ? Duration.zero : gapStart;
    // A second vocal line may overlap a previous, longer one.
    if (start != null && latestVocalEnd != null && start < latestVocalEnd) {
      start = latestVocalEnd;
    }
    if (start != null && line.time - start >= minimumGap) {
      timeline.add(LyricLine(time: start, end: line.time, text: ''));
    }
    timeline.add(line);

    final lastWord = line.words.lastOrNull;
    var end = line.end;
    if (lastWord != null) {
      if (lastWord.end != null && (end == null || lastWord.end! > end)) {
        end = lastWord.end;
      }
      if (end != null && end < lastWord.time) end = null;
    }
    if (end != null && end < line.time) end = null;
    gapStart = end;
    if (end != null && (latestVocalEnd == null || end > latestVocalEnd)) {
      latestVocalEnd = end;
    }
  }
  // No following vocal means no countdown: trailing blank timestamps are
  // intentionally omitted, and credits stay after the last sung line.
  return List.unmodifiable(timeline);
}
