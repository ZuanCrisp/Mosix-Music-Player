import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/re_enrich_result.dart';

void main() {
  for (final locale in ['en', 'id']) {
    test(
      '$locale distinguishes updated, instrumental, and unavailable lyrics',
      () async {
        final l10n = await AppLocalizations.delegate.load(Locale(locale));
        for (final entry in {
          'updated': l10n.trackReEnrichLyricsUpdated,
          'instrumental': l10n.trackInstrumental,
          'not_found': l10n.trackLyricsNotAvailable,
          'preserved': l10n.trackReEnrichLyricsPreserved,
          'disabled': l10n.trackReEnrichLyricsDisabled,
        }.entries) {
          final message = reEnrichCompletionMessage(l10n, {
            'success': true,
            'lyrics_status': entry.key,
          });
          expect(message, '${l10n.trackReEnrichMetadataSaved}\n${entry.value}');
          if (entry.key != 'updated') {
            expect(message, isNot(contains(l10n.trackReEnrichLyricsUpdated)));
          }
        }
        expect(reEnrichCompletionMessage(l10n, {}), l10n.trackReEnrichSuccess);
        expect(
          reEnrichCompletionMessage(l10n, {'lyrics_status': 'not_requested'}),
          l10n.trackReEnrichSuccess,
        );
      },
    );

    test(
      '$locale batch does not label every saved file as lyrics updated',
      () async {
        final l10n = await AppLocalizations.delegate.load(Locale(locale));
        final summary = ReEnrichLyricsSummary();
        for (final status in ['updated', 'instrumental', 'not_found']) {
          summary.add({'lyrics_status': status});
        }
        expect(
          summary.message(l10n, 3, 3),
          [
            '${l10n.trackReEnrichMetadataSaved} (3/3)',
            '${l10n.trackReEnrichLyricsUpdated} (1)',
            '${l10n.trackInstrumental} (1)',
            '${l10n.trackLyricsNotAvailable} (1)',
          ].join('\n'),
        );
        expect(
          summary.message(l10n, 3, 4),
          startsWith(l10n.trackReEnrichSuccessWithFailures(3, 4, 1)),
        );
      },
    );
  }
}
