import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserProfile {
  const UserProfile({this.name = '', this.photoPath});

  final String name;
  final String? photoPath;
}

/// Local identity only. Persist a relative filename so iOS container relocation
/// does not break the avatar after reinstalling an app update.
class UserProfileStore {
  UserProfileStore({
    Future<SharedPreferences> Function()? preferences,
    Future<Directory> Function()? documents,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _documents = documents ?? getApplicationDocumentsDirectory;

  static const _key = 'user_profile_v1';
  final Future<SharedPreferences> Function() _preferences;
  final Future<Directory> Function() _documents;

  Future<Directory> _directory() async =>
      Directory(p.join((await _documents()).path, 'profile'));

  Future<UserProfile> read() async {
    final raw = (await _preferences()).getString(_key);
    if (raw == null) return const UserProfile();
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final name = data['name'] as String? ?? '';
      final photo = data['photo'] as String? ?? '';
      if (!RegExp(r'^avatar-\d+\.png$').hasMatch(photo)) {
        return UserProfile(name: name);
      }
      final file = File(p.join((await _directory()).path, photo));
      return UserProfile(
        name: name,
        photoPath: await file.exists() ? file.path : null,
      );
    } on FormatException {
      return const UserProfile();
    } on TypeError {
      return const UserProfile();
    }
  }

  Future<UserProfile> save({
    required String name,
    Uint8List? photo,
    bool removePhoto = false,
  }) async {
    final previous = await read();
    File? created;
    var path = removePhoto ? null : previous.photoPath;
    try {
      if (photo != null) {
        final directory = await _directory();
        await directory.create(recursive: true);
        created = File(
          p.join(
            directory.path,
            'avatar-${DateTime.now().microsecondsSinceEpoch}.png',
          ),
        );
        await created.writeAsBytes(photo, flush: true);
        path = created.path;
      }
      final updated = UserProfile(name: name.trim(), photoPath: path);
      final saved = await (await _preferences()).setString(
        _key,
        jsonEncode({
          'name': updated.name,
          'photo': path == null ? '' : p.basename(path),
        }),
      );
      if (!saved) throw const FileSystemException('Could not save profile');
      if (previous.photoPath != null && previous.photoPath != path) {
        try {
          await File(previous.photoPath!).delete();
        } on FileSystemException {
          // The new profile is committed; an old file must not block saving.
        }
      }
      return updated;
    } catch (_) {
      if (created != null && await created.exists()) await created.delete();
      rethrow;
    }
  }
}

/// Decode one frame and store a bounded PNG instead of retaining a picker temp
/// path or a full-resolution camera image. The circle crop is applied in UI.
Future<Uint8List> prepareProfilePhoto(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    final scale = longest > 512 ? 512 / longest : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round().clamp(1, 512),
      targetHeight: (descriptor.height * scale).round().clamp(1, 512),
    );
    image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw const FormatException('Unsupported profile photo');
    return png.buffer.asUint8List();
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
