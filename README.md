# Mosix

Mosix is a Flutter music player and library manager with an extension based search and download system. Maintained by **ZuanCrisp**.

## Features

- Search music through installed extensions and prioritize providers.
- Download tracks, albums, and playlists with configurable quality and metadata.
- Manage a local library, playlists, playback queue, lyrics, and download history.
- Play local audio with format, output, and high resolution playback options where supported by the device.
- Edit audio tags and artwork, scan for duplicates, and organize downloaded files.
- Browse network storage and choose Android download folders through the system picker.
- Install extensions from a repository URL or import a locally downloaded extension package.
- Use a responsive interface with multiple languages and light/dark themes.

## Version

Mosix starts at **v1.0.0** (build 1). The Android package is `com.zuancrisp.mosix`.

## Build Android APK

Requirements: Flutter SDK, Android SDK/NDK, Rust toolchain, and Android Rust targets.

```sh
flutter pub get
MOSIX_RUST_ANDROID_ABIS=arm64-v8a MOSIX_DISCORD_SDK=0 ./scripts/build_android.sh --lite
```

Release APKs are written under `build/app/outputs/flutter-apk/`.

## Project layout

- `lib/` — Flutter application
- `rust_backend/` — Rust backend and provider integrations
- `android/`, `ios/` — native platform bridges
- `third_party/` — bundled Flutter plugins and their required notices

## Maintainer

**ZuanCrisp**

## License

Mosix is distributed under the MIT License. See [LICENSE](LICENSE). Third party components retain their respective licenses and notices.
