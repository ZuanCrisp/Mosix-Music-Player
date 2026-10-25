import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

/// Editorial text is display-only. Never load embedded media or execute markup.
DocumentFragment parseEditorialNotes(String value) {
  final fragment = html.parseFragment(value);
  for (final element in fragment.querySelectorAll(
    'script, style, iframe, object, template',
  )) {
    element.remove();
  }
  return fragment;
}

String? albumDescriptionFromMetadata(Map<String, dynamic>? metadata) {
  final notes =
      metadata?['editorial_notes'] ??
      metadata?['editorialNotes'] ??
      metadata?['description'];
  final candidates = notes is Map
      ? [notes['standard'], notes['short']]
      : [notes];
  for (final candidate in candidates) {
    if (candidate is String &&
        (parseEditorialNotes(candidate).text ?? '').trim().isNotEmpty) {
      return candidate.trim();
    }
  }
  return null;
}
