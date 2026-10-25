import 'package:mornye/l10n/l10n.dart';

String? reEnrichLyricsMessage(AppLocalizations l10n, String? status) =>
    switch (status) {
      'updated' => l10n.trackReEnrichLyricsUpdated,
      'instrumental' => l10n.trackInstrumental,
      'not_found' => l10n.trackLyricsNotAvailable,
      'preserved' => l10n.trackReEnrichLyricsPreserved,
      'disabled' => l10n.trackReEnrichLyricsDisabled,
      _ => null,
    };

String reEnrichCompletionMessage(
  AppLocalizations l10n,
  Map<String, dynamic> result,
) {
  final lyrics = reEnrichLyricsMessage(
    l10n,
    result['lyrics_status'] as String?,
  );
  return lyrics == null
      ? l10n.trackReEnrichSuccess
      : '${l10n.trackReEnrichMetadataSaved}\n$lyrics';
}

/// Count lyric outcomes only after the metadata and sidecar writes finish.
/// Metadata saved is independent of whether new lyrics could be found.
class ReEnrichLyricsSummary {
  final _counts = <String, int>{};

  void add(Map<String, dynamic> result) {
    final status = result['lyrics_status'] as String?;
    if (status == null || status == 'not_requested') return;
    _counts.update(status, (count) => count + 1, ifAbsent: () => 1);
  }

  String message(AppLocalizations l10n, int saved, int total) {
    final failed = total - saved;
    final lines = [
      failed > 0
          ? l10n.trackReEnrichSuccessWithFailures(saved, total, failed)
          : _counts.isEmpty
          ? '${l10n.trackReEnrichSuccess} ($saved/$total)'
          : '${l10n.trackReEnrichMetadataSaved} ($saved/$total)',
      for (final entry in _counts.entries)
        if (reEnrichLyricsMessage(l10n, entry.key) case final label?)
          '$label (${entry.value})',
    ];
    return lines.join('\n');
  }
}
