import 'package:flutter/widgets.dart';
import 'package:mornye/utils/string_utils.dart';

/// Editable tags and request generations, independent of sheet navigation.
class MetadataEditorController {
  static const fieldKeys = <String>[
    'title',
    'artist',
    'album',
    'album_artist',
    'date',
    'track_number',
    'total_tracks',
    'disc_number',
    'total_discs',
    'genre',
    'isrc',
    'lyrics',
    'label',
    'copyright',
    'composer',
    'comment',
    'album_type',
    'explicit',
    'upc',
    'cover',
  ];

  final Map<String, TextEditingController> _fields;
  final Set<String> autoFillFields = {};
  bool explicit;
  int _generation = 0;
  bool _disposed = false;

  MetadataEditorController(Map<String, String> initialValues)
    : _fields = {
        for (final key in fieldKeys)
          if (key != 'explicit' && key != 'cover')
            key: TextEditingController(text: initialValues[key] ?? ''),
      },
      explicit = parseExplicitFlag(initialValues['explicit']) == true {
    for (final field in _fields.values) {
      var previousText = field.text;
      field.addListener(() {
        if (field.text == previousText) return;
        previousText = field.text;
        invalidateLookup();
      });
    }
  }

  TextEditingController? operator [](String key) => _fields[key];

  Map<String, String> get values => {
    for (final entry in _fields.entries) entry.key: entry.value.text,
    'explicit': explicit ? '1' : '0',
  };

  int beginLookup() => ++_generation;
  void invalidateLookup() => _generation++;
  bool isCurrent(int generation) => !_disposed && generation == _generation;

  int apply(Map<String, String> values) {
    var filled = 0;
    for (final key in autoFillFields) {
      final value = values[key];
      if (value == null) continue;
      if (key == 'explicit') {
        final parsed = parseExplicitFlag(value);
        if (parsed == null) continue;
        explicit = parsed;
      } else {
        final field = _fields[key];
        if (field == null) continue;
        field.text = value;
      }
      filled++;
    }
    return filled;
  }

  void selectEmptyFields({required bool hasCover}) {
    autoFillFields
      ..clear()
      ..addAll(_fields.keys.where((key) => _fields[key]!.text.trim().isEmpty));
    if (!hasCover) autoFillFields.add('cover');
  }

  Map<String, String> saveMetadata({required String artistTagMode}) {
    final tags = values;
    tags['track_total'] = tags.remove('total_tracks')!;
    tags['disc_total'] = tags.remove('total_discs')!;
    tags['compilation'] =
        tags['album_type']!.trim().toLowerCase() == 'compilation' ? '1' : '0';
    tags['artist_tag_mode'] = artistTagMode;
    return tags;
  }

  void dispose() {
    _disposed = true;
    for (final field in _fields.values) {
      field.dispose();
    }
  }
}
