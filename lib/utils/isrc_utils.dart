final RegExp _canonicalIsrcPattern = RegExp(r'^[A-Z]{2}[A-Z0-9]{3}\d{7}$');

String normalizeIsrc(String? value) =>
    (value ?? '').trim().toUpperCase().replaceAll(RegExp(r'[-\s]'), '');

/// Returns the compact canonical value only when [value] is a valid ISRC.
/// Invalid provider/tag values remain visible and copyable without mutation.
String canonicalIsrcForCopy(String? value) {
  final original = value?.trim() ?? '';
  final normalized = normalizeIsrc(original);
  return _canonicalIsrcPattern.hasMatch(normalized) ? normalized : original;
}

/// Formats a valid canonical ISRC for display without changing stored tags.
///
/// Example: `AA9BQ2200061` becomes `AA-9BQ-22-00061`.
String formatIsrcForDisplay(String? value) {
  final original = value?.trim() ?? '';
  final canonical = canonicalIsrcForCopy(original);
  if (!_canonicalIsrcPattern.hasMatch(canonical)) {
    return original;
  }
  return '${canonical.substring(0, 2)}-'
      '${canonical.substring(2, 5)}-'
      '${canonical.substring(5, 7)}-'
      '${canonical.substring(7)}';
}
