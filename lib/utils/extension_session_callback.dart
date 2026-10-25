typedef ExtensionSessionGrantCallback = ({String grant, String state});

ExtensionSessionGrantCallback? parseExtensionSessionGrantCallback(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  String? grant;
  String? state;
  final uri = Uri.tryParse(trimmed);
  if (uri != null) {
    grant = _nonEmpty(
      uri.queryParameters['grant'] ?? uri.queryParameters['code'],
    );
    state = _nonEmpty(uri.queryParameters['state']);

    final nestedCallback = _nonEmpty(uri.queryParameters['cb']);
    if (grant == null && nestedCallback != null) {
      final nested = parseExtensionSessionGrantCallback(nestedCallback);
      if (nested != null) return nested;
    }
  }

  grant ??= _decodedRegexGroup(
    trimmed,
    RegExp(r'(?:^|[?&#\s])grant=([^&#\s]+)'),
  );
  grant ??= _decodedRegexGroup(
    trimmed,
    RegExp(r'(?:^|[?&#\s])code=([^&#\s]+)'),
  );
  state ??= _decodedRegexGroup(
    trimmed,
    RegExp(r'(?:^|[?&#\s])state=([^&#\s]+)'),
  );

  grant = _nonEmpty(grant);
  state = _nonEmpty(state);
  if (grant == null || state == null) return null;
  return (grant: grant, state: state);
}

String? extensionCallbackStateFromVerificationUri(Uri uri, [int depth = 0]) {
  if (depth > 3) return null;

  final directState = _nonEmpty(uri.queryParameters['state']);
  if (directState != null) return directState;

  for (final key in const ['cb', 'callback', 'callback_url', 'redirect_uri']) {
    final nestedText = _nonEmpty(uri.queryParameters[key]);
    if (nestedText == null) continue;
    final nestedUri = Uri.tryParse(nestedText);
    if (nestedUri == null) continue;
    final nestedState = extensionCallbackStateFromVerificationUri(
      nestedUri,
      depth + 1,
    );
    if (nestedState != null) return nestedState;
  }
  return null;
}

String? _decodedRegexGroup(String input, RegExp regex) {
  final value = _nonEmpty(regex.firstMatch(input)?.group(1));
  if (value == null) return null;
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return null;
  }
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
