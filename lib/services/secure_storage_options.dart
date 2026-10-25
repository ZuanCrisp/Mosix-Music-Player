import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// All clients share the default Android storage namespace. A failed read or
// migration in any client must not erase the extension master key stored there.
const secureStorageAndroidOptions = AndroidOptions(
  resetOnError: false,
  migrateOnAlgorithmChange: true,
  migrateWithBackup: true,
  keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
  storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
);

// The data protection keychain needs a signed keychain-access-groups
// entitlement; the login keychain works for Developer ID and local builds.
// Linux keeps the default libsecret options.
const secureStorageMacOsOptions = MacOsOptions(
  usesDataProtectionKeychain: false,
);
