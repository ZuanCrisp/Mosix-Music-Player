import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/utils/home_greeting.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  String at(int hour, {String name = '', int variant = 0}) => homeGreeting(
    l10n,
    name: name,
    now: DateTime(2026, 10, 18, hour),
    variant: variant,
  );

  test('follows the time of day', () {
    expect(at(8), 'Good morning');
    expect(at(13), 'Good afternoon');
    expect(at(18), 'Good evening');
    expect(at(23), 'Good night');
    expect(at(3), 'Good night');
  });

  test('variants rotate within the same part of the day', () {
    final phrases = {for (var i = 0; i < 3; i++) at(8, variant: i)};
    expect(phrases, {'Good morning', 'Rise and shine', 'Fresh start'});
    expect(at(8, variant: 3), at(8));
  });

  test('addresses the profile by first name only', () {
    expect(at(23, name: '  Alex Rivera '), 'Good night, Alex');
    expect(at(23, name: '   '), 'Good night');
  });
}
