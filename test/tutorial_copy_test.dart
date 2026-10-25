import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';

void main() {
  group('setup and tutorial copy', () {
    test('uses the current app name and extension-based workflow', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final strings = lookupAppLocalizations(locale);
        final setupTagline = strings.setupDownloadInFlac.toLowerCase();
        final firstTip = strings.tutorialWelcomeTip1.toLowerCase();

        expect(
          strings.tutorialWelcomeTitle,
          contains('Mornye'),
          reason: 'Unexpected app name for $locale',
        );
        expect(strings.appName, 'Mornye', reason: 'App name for $locale');
        expect(
          setupTagline,
          isNot(contains('spotify')),
          reason: 'Provider-specific setup tagline for $locale',
        );
        expect(
          firstTip,
          isNot(anyOf(contains('spotify'), contains('deezer'))),
          reason: 'Provider-specific tutorial tip for $locale',
        );
      }
    });

    test('English and Indonesian describe the current feature set', () {
      final english = lookupAppLocalizations(const Locale('en'));
      final indonesian = lookupAppLocalizations(const Locale('id'));

      expect(english.tutorialWelcomeDesc, contains('extensions'));
      expect(english.tutorialLibraryTip2, contains('built-in player'));
      expect(indonesian.tutorialWelcomeDesc, contains('ekstensi'));
      expect(indonesian.tutorialLibraryTip2, contains('pemutar bawaan'));
    });
  });
}
