# Contributing to Mosix

Mosix is currently maintained by ZuanCrisp. Please open an issue before proposing a larger change.

## Android build

Use the Flutter version pinned in `.fvmrc`, the Android SDK/NDK versions configured in `android/app/build.gradle.kts`, and the Rust toolchain pinned under `rust_backend/`.

```sh
flutter pub get
MOSIX_RUST_ANDROID_ABIS=arm64-v8a MOSIX_DISCORD_SDK=0 ./scripts/build_android.sh --lite
```

The script builds a Lite APK without Discord Rich Presence. Never commit credentials, signing keys, media files, or generated build artifacts.

## Changes

Keep changes focused, preserve third-party license notices, and describe user-visible behavior in the pull request.
