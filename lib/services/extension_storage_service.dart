import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/utils/desktop_platform.dart';

const _extensionMasterKeyName = 'extension_storage_master_key_v2';

class ExtensionStoragePaths {
  const ExtensionStoragePaths({
    required this.extensionsDir,
    required this.dataDir,
    required this.masterKey,
  });

  final String extensionsDir;
  final String dataDir;
  final String masterKey;
}

class ExtensionStorageService {
  ExtensionStorageService._();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
  );
  static Future<ExtensionStoragePaths>? _preparing;

  @visibleForTesting
  static void resetForTesting() => _preparing = null;

  static Future<ExtensionStoragePaths> prepare() {
    return _preparing ??= _prepare().catchError((
      Object error,
      StackTrace stack,
    ) {
      // A transient filesystem/keystore failure must not poison every retry
      // until the process is restarted.
      _preparing = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  static Future<ExtensionStoragePaths> _prepare() async {
    final supportDir = await getApplicationSupportDirectory();
    final extensionsDir = Directory(p.join(supportDir.path, 'extensions'));
    final dataDir = Directory(p.join(supportDir.path, 'extension_data'));

    // Mobile builds once kept extensions in the app's private Documents
    // folder. On desktop that folder is the user's own Documents, which never
    // held app storage, so nothing there may be moved.
    if (!isDesktopPlatform) {
      final documentsDir = await getApplicationDocumentsDirectory();
      await _migrateDirectory(
        Directory(p.join(documentsDir.path, 'extensions')),
        extensionsDir,
      );
      await _migrateDirectory(
        Directory(p.join(documentsDir.path, 'extension_data')),
        dataDir,
      );
    }
    await extensionsDir.create(recursive: true);
    await dataDir.create(recursive: true);

    return ExtensionStoragePaths(
      extensionsDir: extensionsDir.path,
      dataDir: dataDir.path,
      masterKey: await _loadOrCreateMasterKey(dataDir),
    );
  }

  static Future<String> _loadOrCreateMasterKey(Directory dataDir) async {
    final existing = await _secureStorage.read(key: _extensionMasterKeyName);
    if (existing != null) {
      try {
        if (base64Decode(existing).length == 32) return existing;
      } on FormatException {
        // Preserve the stored value for recovery instead of silently rotating it.
      }
      throw StateError(
        'The extension storage key is invalid. Existing extension data has '
        'been preserved.',
      );
    }

    // Plaintext settings and salt-based legacy credentials can be migrated with
    // a new key. Encrypted settings require the original key; generating another
    // one would leave every installed extension permanently unreadable.
    await for (final entry in dataDir.list(followLinks: false)) {
      if (entry is Directory &&
          await FileSystemEntity.type(
                p.join(entry.path, 'settings.enc'),
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
        throw StateError(
          'The extension storage key is missing. Existing encrypted extension '
          'data has been preserved.',
        );
      }
    }

    final random = Random.secure();
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    final encoded = base64Encode(key);
    await _secureStorage.write(key: _extensionMasterKeyName, value: encoded);
    return encoded;
  }

  static Future<void> _migrateDirectory(
    Directory source,
    Directory destination,
  ) async {
    if (p.equals(source.path, destination.path)) {
      return;
    }
    final sourceType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) return;
    if (sourceType == FileSystemEntityType.link) {
      await Link(source.path).delete();
      return;
    }
    if (sourceType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Extension storage path is not a directory',
        source.path,
      );
    }
    if (await FileSystemEntity.type(destination.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'Refusing extension storage symlink',
        destination.path,
      );
    }

    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final targetPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _migrateDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        final target = File(targetPath);
        await target.parent.create(recursive: true);
        if (await target.exists()) {
          final sourceModified = await entity.lastModified();
          final targetModified = await target.lastModified();
          if (!sourceModified.isAfter(targetModified)) {
            await entity.delete();
            continue;
          }
        }
        await _copyFileAtomically(entity, target);
        await entity.delete();
      } else if (entity is Link) {
        // Extension storage must never preserve links into another sandbox.
        await entity.delete();
      }
    }
    if (await source.exists() && await source.list().isEmpty) {
      await source.delete();
    }
  }

  static Future<void> _copyFileAtomically(File source, File target) async {
    final nonce = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final temporary = File('${target.path}.migration-$nonce.tmp');
    try {
      await source.openRead().pipe(temporary.openWrite());
      final sourceLength = await source.length();
      if (await temporary.length() != sourceLength) {
        throw const FileSystemException('Incomplete extension storage copy');
      }
      try {
        await temporary.rename(target.path);
      } on FileSystemException {
        // Windows cannot atomically replace an existing file. Mobile platforms
        // take the first branch; this fallback keeps development migrations
        // functional while retaining the source until replacement succeeds.
        if (!await target.exists()) rethrow;
        await target.delete();
        await temporary.rename(target.path);
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
