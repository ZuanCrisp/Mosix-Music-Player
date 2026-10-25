import 'dart:io';

/// Evicts complete analysis bundles (metadata, combined image and channels).
/// Leases protect cache reads/writes while a card changes tracks or channels.
class AudioAnalysisCache {
  final Map<String, int> _active = {};
  Future<void> _sweep = Future<void>.value();
  static final _filename = RegExp(r'^([a-f0-9]+)(?:_ch\d+)?\.(json|png)$');

  void Function() retain(String key) {
    _active.update(key, (count) => count + 1, ifAbsent: () => 1);
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = _active[key]! - 1;
      if (count == 0) {
        _active.remove(key);
      } else {
        _active[key] = count;
      }
    };
  }

  Future<void> trim(
    Directory directory, {
    int maxBytes = 64 * 1024 * 1024,
    int targetBytes = 48 * 1024 * 1024,
  }) {
    assert(targetBytes >= 0 && targetBytes <= maxBytes);
    _sweep = _sweep.then((_) async {
      try {
        if (!await directory.exists()) return;
        final bundles = <String, _AnalysisBundle>{};
        var total = 0;
        await for (final file in directory.list(followLinks: false)) {
          if (file is! File) continue;
          final match = _filename.firstMatch(file.uri.pathSegments.last);
          if (match == null) continue;
          final stat = await file.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          final bundle = bundles.putIfAbsent(match[1]!, _AnalysisBundle.new);
          bundle.files.add(file);
          if (bundle.modified.isBefore(stat.modified)) {
            bundle.modified = stat.modified;
          }
          total += stat.size;
        }
        if (total <= maxBytes) return;
        final oldest = bundles.entries.toList()
          ..sort((a, b) => a.value.modified.compareTo(b.value.modified));
        for (final entry in oldest) {
          if (total <= targetBytes) break;
          if (_active.containsKey(entry.key)) continue;
          for (final file in entry.value.files) {
            // A cache reader can acquire a lease during the asynchronous scan.
            if (_active.containsKey(entry.key)) break;
            try {
              final size = await file.length();
              if (_active.containsKey(entry.key)) break;
              await file.delete();
              total -= size;
            } on FileSystemException {
              // Cache cleanup or a metadata refresh can race with this sweep.
            }
          }
        }
      } on FileSystemException {
        // Optional cache maintenance must not fail audio analysis.
      }
    });
    return _sweep;
  }
}

class _AnalysisBundle {
  final List<File> files = [];
  DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);
}
