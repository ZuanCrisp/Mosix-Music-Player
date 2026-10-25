import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/metadata_editor_controller.dart';

void main() {
  test('save snapshots preserve empty tags and explicit track/disc totals', () {
    final editor = MetadataEditorController({
      'title': 'Song',
      'artist': 'Artist One; Artist Two',
      'total_tracks': '12',
      'total_discs': '2',
      'album_type': ' Compilation ',
      'explicit': 'true',
    });
    final tags = editor.saveMetadata(artistTagMode: 'all');
    editor['title']!.text = 'Changed';
    editor.dispose();

    expect(tags['title'], 'Song');
    expect(tags['artist'], 'Artist One; Artist Two');
    expect(tags['lyrics'], '');
    expect(tags['track_total'], '12');
    expect(tags['disc_total'], '2');
    expect(tags['compilation'], '1');
    expect(tags['explicit'], '1');
    expect(tags['artist_tag_mode'], 'all');
    expect(tags.containsKey('total_tracks'), isFalse);
    expect(tags.containsKey('total_discs'), isFalse);
  });

  test('edits and disposal invalidate asynchronous lookup results', () {
    final editor = MetadataEditorController({'title': 'Song'});
    final first = editor.beginLookup();
    expect(editor.isCurrent(first), isTrue);
    editor['title']!.text = 'Other Song';
    expect(editor.isCurrent(first), isFalse);
    final second = editor.beginLookup();
    editor.dispose();
    expect(editor.isCurrent(second), isFalse);
  });

  test('caret and composition changes keep pending lookup results current', () {
    final editor = MetadataEditorController({'title': 'Song'});
    addTearDown(editor.dispose);
    final generation = editor.beginLookup();
    final title = editor['title']!;
    title.selection = const TextSelection.collapsed(offset: 2);
    expect(editor.isCurrent(generation), isTrue);
    title.value = title.value.copyWith(
      composing: const TextRange(start: 0, end: 4),
    );
    expect(editor.isCurrent(generation), isTrue);
    title.clearComposing();
    expect(editor.isCurrent(generation), isTrue);
    title.text = 'Other Song';
    expect(editor.isCurrent(generation), isFalse);
  });

  test(
    'empty-field selection and apply respect manual tags and explicit false',
    () {
      final editor = MetadataEditorController({'title': 'Manual Title'});
      addTearDown(editor.dispose);
      editor.selectEmptyFields(hasCover: true);
      expect(editor.autoFillFields, isNot(contains('title')));
      expect(editor.autoFillFields, isNot(contains('cover')));
      expect(editor.autoFillFields, isNot(contains('explicit')));
      editor.autoFillFields.add('explicit');
      editor.explicit = true;
      final filled = editor.apply({
        'title': 'Online Title',
        'artist': 'Online Artist',
        'explicit': '0',
      });
      expect(filled, 2);
      expect(editor['title']!.text, 'Manual Title');
      expect(editor['artist']!.text, 'Online Artist');
      expect(editor.explicit, isFalse);
      editor.selectEmptyFields(hasCover: false);
      expect(editor.autoFillFields, contains('cover'));
    },
  );
}
