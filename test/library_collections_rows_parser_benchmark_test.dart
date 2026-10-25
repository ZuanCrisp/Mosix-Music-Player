import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Parse-only experiment: both readers perform the same outer/inner JSON
// decoding and ordered checksum. It excludes SQL, native serialization,
// isolate startup/transfers, model hydration and membership construction.
class _DecodedRows implements Sink<String> {
  int count = 0;
  int checksum = 0;

  @override
  void add(String line) {
    final envelope = jsonDecode(line) as Map<String, dynamic>;
    final row = Map<String, dynamic>.from(envelope['row'] as Map);
    final track =
        jsonDecode(row['track_json'] as String) as Map<String, dynamic>;
    final text =
        '${envelope['kind']}|${row['track_key']}|${track['name']}|${track['comment']}';
    for (final unit in text.codeUnits) {
      checksum = ((checksum * 31) + unit) & 0x7fffffff;
    }
    count++;
  }

  @override
  void close() {}
}

Future<({int count, int checksum})> _parse(File file, bool chunked) async {
  final rows = _DecodedRows();
  if (chunked) {
    final lines = const LineSplitter().startChunkedConversion(rows);
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      lines.add(chunk);
    }
    lines.close();
  } else {
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      rows.add(line);
    }
  }
  return (count: rows.count, checksum: rows.checksum);
}

void main() {
  test('paired native collection rows parse-only benchmark', () async {
    final directory = await Directory.systemTemp.createTemp(
      'collection-parser-benchmark-',
    );
    try {
      final file = File('${directory.path}/rows.ndjson');
      const count = 8000;
      await file.writeAsString(
        [
          for (var index = 0; index < count; index++)
            jsonEncode({
              'kind': index.isEven ? 'wishlist' : 'loved',
              'row': {
                'track_key': 'example:$index',
                'added_at': '2026-10-07T00:00:00.000Z',
                'track_json': jsonEncode({
                  'id': '$index',
                  'name': 'Song $index 音楽 🎵',
                  'artistName': 'Artist ${index % 100}',
                  'albumName': 'Album ${index ~/ 12}',
                  'duration': 180,
                  'comment': '"quoted" \\ / \r\n ${'x' * 512}',
                  'coverUrl': 'https://example.test/$index.jpg',
                  'availability': {'tidal': true, 'qobuz': false},
                }),
              },
            }),
        ].join('\n'),
      );
      final expected = await _parse(file, false);
      expect(expected.count, count);
      // Warm both codecs/file paths before alternating paired measurements.
      for (var warm = 0; warm < 2; warm++) {
        expect(await _parse(file, true), expected);
        expect(await _parse(file, false), expected);
      }
      final old = <int>[];
      final chunked = <int>[];
      for (var sample = 0; sample < 7; sample++) {
        for (final useChunked
            in sample.isEven ? [false, true] : [true, false]) {
          final watch = Stopwatch()..start();
          final actual = await _parse(file, useChunked);
          watch.stop();
          expect(actual, expected);
          (useChunked ? chunked : old).add(watch.elapsedMicroseconds);
        }
      }
      int median(List<int> samples) =>
          (List<int>.of(samples)..sort())[samples.length ~/ 2];
      final report = {
        'scope':
            'parse only: file read, strict UTF-8 decode, outer/inner JSON decode, ordered checksum; excludes full collection loading/hydration',
        'platform': Platform.operatingSystem,
        'mode': 'flutter test host',
        'rows': count,
        'bytes': await file.length(),
        'checksum': expected.checksum,
        'async_line_stream_us': old,
        'chunked_line_sink_us': chunked,
        'async_line_stream_median_us': median(old),
        'chunked_line_sink_median_us': median(chunked),
        'parity': true,
      };
      const output = String.fromEnvironment('COLLECTION_ROWS_PARSER_OUTPUT');
      if (output.isNotEmpty) {
        final result = File(output);
        await result.parent.create(recursive: true);
        await result.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
        );
      }
      // ignore: avoid_print
      print('COLLECTION_ROWS_PARSER_REPORT ${jsonEncode(report)}');
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !const bool.fromEnvironment('RUN_COLLECTION_ROWS_PARSER_BENCHMARK'));
}
