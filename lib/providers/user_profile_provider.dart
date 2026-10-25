import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/user_profile_store.dart';

final userProfileStoreProvider = Provider<UserProfileStore>(
  (ref) => UserProfileStore(),
);

final userProfileProvider =
    AsyncNotifierProvider<UserProfileNotifier, UserProfile>(
      UserProfileNotifier.new,
    );

class UserProfileNotifier extends AsyncNotifier<UserProfile> {
  @override
  Future<UserProfile> build() => ref.watch(userProfileStoreProvider).read();

  Future<void> restoreFromBackup(UserProfile profile) async {
    final path = profile.photoPath;
    final photo = path == null
        ? null
        : await prepareProfilePhoto(await File(path).readAsBytes());
    await save(name: profile.name, photo: photo, removePhoto: photo == null);
  }

  Future<void> save({
    required String name,
    Uint8List? photo,
    bool removePhoto = false,
  }) async {
    await future;
    final profile = await ref
        .read(userProfileStoreProvider)
        .save(name: name, photo: photo, removePhoto: removePhoto);
    state = AsyncData(profile);
  }
}
