part of '../platform_bridge.dart';

Object? _decodeJsonInBackground(String json) => jsonDecode(json);
String _encodeJsonInBackground(Object? value) => jsonEncode(value);

String _encodeBoundedLookupCacheInBackground(Map<String, dynamic> entries) {
  final result = StringBuffer('{');
  var bytes = 2; // Opening and closing braces.
  var count = 0;
  for (final entry in entries.entries) {
    final fragment =
        '${_encodeJsonInBackground(entry.key)}:${_encodeJsonInBackground(entry.value)}';
    final entryBytes = utf8.encode(fragment).length;
    final separatorBytes = count == 0 ? 0 : 1;
    if (entryBytes > PlatformBridge._persistentCacheMaxEntryBytes ||
        bytes + separatorBytes + entryBytes >
            PlatformBridge._persistentCacheMaxBytes) {
      continue;
    }
    if (count > 0) result.write(',');
    result.write(fragment);
    bytes += separatorBytes + entryBytes;
    count++;
  }
  result.write('}');
  return result.toString();
}

Object? _decodeJsonFileInBackground(String path) {
  final contents = File(path).readAsStringSync();
  return contents.isEmpty ? null : jsonDecode(contents);
}
