import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// All clients share the default Android storage namespace. A failed read or
// migration in any client must not erase the extension master key stored there.
const secureStorageAndroidOptions = AndroidOptions(
  resetOnError: false,
  migrateWithBackup: true,
);
