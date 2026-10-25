import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:mornye/services/platform_bridge.dart';

/// Minimal ID3v2.3 USLT writer used after FFmpeg metadata embedding.
///
/// It intentionally supports only plain ID3v2.3 tags without extended,
/// compressed, or unsynchronized headers. Unsupported tags are left unchanged.
class Id3v23Lyrics {
  const Id3v23Lyrics._();

  // Artwork can make tags large, but never allocate an audio-sized buffer for
  // a malformed size field. Unsupported/oversized tags leave the file intact.
  static const int _maxTagBytes = 32 << 20;

  /// Replaces lyrics while streaming the audio tail to a sibling temporary
  /// file. The original is replaced only after all output has been flushed.
  static Future<bool> writeUnsyncedLyricsToFile(
    File file,
    String lyrics,
  ) async {
    try {
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'write_id3v23_lyrics',
        'file_path': file.path,
        'lyrics': lyrics,
      });
      return result['updated'] == true;
    } on MissingPluginException {
      final path = file.path;
      return Isolate.run(() => _writeUnsyncedLyricsToFile(File(path), lyrics));
    }
  }

  static Future<bool> _writeUnsyncedLyricsToFile(
    File file,
    String lyrics,
  ) async {
    final input = await file.open();
    late final Uint8List updatedTag;
    var audioOffset = 0;
    try {
      final header = await input.read(10);
      if (_hasId3Header(header)) {
        final tagSize = _readSynchsafeInt(header, 6);
        if (header[3] != 3 ||
            (header[5] & (0x80 | 0x40 | 0x20)) != 0 ||
            tagSize == null ||
            tagSize > _maxTagBytes ||
            tagSize + 10 > await input.length()) {
          return false;
        }
        await input.setPosition(0);
        final tag = await input.read(tagSize + 10);
        if (tag.length != tagSize + 10) return false;
        final updated = writeUnsyncedLyrics(tag, lyrics);
        if (updated == null) return false;
        updatedTag = updated;
        audioOffset = tagSize + 10;
      } else {
        updatedTag = _buildTag(_buildUnsyncedLyricsFrame(lyrics));
      }
    } finally {
      await input.close();
    }

    final staging = await file.parent.createTemp('.mornye-lyrics-');
    try {
      final output = File('${staging.path}${Platform.pathSeparator}audio.mp3');
      final sink = output.openWrite();
      try {
        sink.add(updatedTag);
        await sink.addStream(file.openRead(audioOffset));
        await sink.flush();
      } finally {
        await sink.close();
      }
      await output.rename(file.path);
      return true;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  static Uint8List? writeUnsyncedLyrics(Uint8List bytes, String lyrics) {
    final lyricsFrame = _buildUnsyncedLyricsFrame(lyrics);

    if (!_hasId3Header(bytes)) {
      final builder = BytesBuilder(copy: false)
        ..add(_buildTag(lyricsFrame))
        ..add(bytes);
      return builder.toBytes();
    }

    if (bytes.length < 10 || bytes[3] != 3) {
      return null;
    }

    final flags = bytes[5];
    const unsupportedFlags = 0x80 | 0x40 | 0x20;
    if ((flags & unsupportedFlags) != 0) {
      return null;
    }

    final tagSize = _readSynchsafeInt(bytes, 6);
    if (tagSize == null) return null;

    final tagEnd = 10 + tagSize;
    if (tagEnd < 10 || tagEnd > bytes.length) {
      return null;
    }

    final tagPayload = bytes.sublist(10, tagEnd);
    final preservedFrames = _removeFrames(tagPayload, {'USLT'});
    final newPayload = BytesBuilder(copy: false)
      ..add(preservedFrames)
      ..add(lyricsFrame);

    final newTag = _buildTag(newPayload.toBytes());
    final builder = BytesBuilder(copy: false)
      ..add(newTag)
      ..add(bytes.sublist(tagEnd));
    return builder.toBytes();
  }

  static bool _hasId3Header(Uint8List bytes) {
    return bytes.length >= 10 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33;
  }

  static Uint8List _removeFrames(Uint8List tagPayload, Set<String> frameIds) {
    final builder = BytesBuilder(copy: false);
    var offset = 0;

    while (offset + 10 <= tagPayload.length) {
      final idBytes = tagPayload.sublist(offset, offset + 4);
      if (idBytes.every((byte) => byte == 0)) break;

      final frameId = ascii.decode(idBytes, allowInvalid: true);
      if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(frameId)) break;

      final frameSize = _readUint32(tagPayload, offset + 4);
      if (frameSize <= 0 || offset + 10 + frameSize > tagPayload.length) {
        break;
      }

      if (!frameIds.contains(frameId)) {
        builder.add(tagPayload.sublist(offset, offset + 10 + frameSize));
      }

      offset += 10 + frameSize;
    }

    return builder.toBytes();
  }

  static Uint8List _buildTag(Uint8List payload) {
    final header = Uint8List(10)
      ..[0] = 0x49
      ..[1] = 0x44
      ..[2] = 0x33
      ..[3] = 3;

    final size = _writeSynchsafeInt(payload.length);
    header.setRange(6, 10, size);

    final builder = BytesBuilder(copy: false)
      ..add(header)
      ..add(payload);
    return builder.toBytes();
  }

  static Uint8List _buildUnsyncedLyricsFrame(String lyrics) {
    final payload = BytesBuilder(copy: false)
      ..add(const [0x01, 0x65, 0x6e, 0x67])
      ..add(const [0xff, 0xfe, 0x00, 0x00])
      ..add(_utf16LeWithBom(lyrics));

    return _buildFrame('USLT', payload.toBytes());
  }

  static Uint8List _buildFrame(String frameId, Uint8List payload) {
    final header = Uint8List(10);
    header.setRange(0, 4, ascii.encode(frameId));
    final size = _writeUint32(payload.length);
    header.setRange(4, 8, size);

    final builder = BytesBuilder(copy: false)
      ..add(header)
      ..add(payload);
    return builder.toBytes();
  }

  static Uint8List _utf16LeWithBom(String value) {
    final bytes = BytesBuilder(copy: false)..add(const [0xff, 0xfe]);
    for (final codeUnit in value.codeUnits) {
      bytes.add([codeUnit & 0xff, (codeUnit >> 8) & 0xff]);
    }
    return bytes.toBytes();
  }

  static int? _readSynchsafeInt(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return null;

    final b0 = bytes[offset];
    final b1 = bytes[offset + 1];
    final b2 = bytes[offset + 2];
    final b3 = bytes[offset + 3];
    if ((b0 | b1 | b2 | b3) & 0x80 != 0) return null;

    return (b0 << 21) | (b1 << 14) | (b2 << 7) | b3;
  }

  static Uint8List _writeSynchsafeInt(int value) {
    return Uint8List.fromList([
      (value >> 21) & 0x7f,
      (value >> 14) & 0x7f,
      (value >> 7) & 0x7f,
      value & 0x7f,
    ]);
  }

  static int _readUint32(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static Uint8List _writeUint32(int value) {
    return Uint8List.fromList([
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
  }
}
