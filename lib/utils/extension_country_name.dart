import 'package:flutter/widgets.dart';
import 'package:mornye/l10n/l10n.dart';

String extensionCountryName(BuildContext context, String code) {
  final l10n = context.l10n;
  return switch (code.toUpperCase()) {
    'US' => l10n.regionCountryUS,
    'GB' => l10n.regionCountryGB,
    'FR' => l10n.regionCountryFR,
    'DE' => l10n.regionCountryDE,
    'IT' => l10n.regionCountryIT,
    'ES' => l10n.regionCountryES,
    'JP' => l10n.regionCountryJP,
    'KR' => l10n.regionCountryKR,
    'IN' => l10n.regionCountryIN,
    'ID' => l10n.regionCountryID,
    'BR' => l10n.regionCountryBR,
    'MX' => l10n.regionCountryMX,
    'AU' => l10n.regionCountryAU,
    'CA' => l10n.regionCountryCA,
    'XK' => l10n.regionCountryXK,
    _ => code.toUpperCase(),
  };
}
