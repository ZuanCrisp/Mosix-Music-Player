<div align="center">
  <img src="logo.svg" alt="Mosix logo" width="150">
  <h1>Mosix</h1>
  <p>A music player for your local library, offline listening, lyrics, and service extensions.</p>
  <p><strong>Flutter · Rust · Android</strong></p>
</div>

## A closer look

<table>
  <tr>
    <td align="center"><strong>Your music</strong></td>
    <td align="center"><strong>Lyrics in sync with playback</strong></td>
  </tr>
  <tr>
    <td><img src="assets/readme/songs.png" alt="Mosix now playing screen" width="360"></td>
    <td><img src="assets/readme/lyrics.png" alt="Mosix lyrics screen" width="360"></td>
  </tr>
</table>

## What Mosix can do

- Find music with installed extensions and choose preferred providers.
- Play local music offline, manage queues and playlists, and view synced lyrics.
- Download tracks, albums, and playlists with configurable quality and metadata.
- Organize a local library, sort by file size, edit tags and artwork, and review download history.
- Connect extension repositories or import extension packages.
- Browse network storage, including Subsonic servers, and choose Android download folders through the system picker.
- Use light or dark themes and multiple languages.

## Extensions

Add the official extension repository in Mosix:

```text
https://raw.githubusercontent.com/ZuanCrisp/Mosix-Extension/main/registry.json
```

The official Mosix Extension repository is included by default. You can also add it from **Extensions → Add Extension Repository** with the URL above. Extensions do not impose a minimum Mosix version.

## Version

**Mosix 5.2.6 (165)** · Android package: `com.zuancrisp.mosix`

## Build Android APK

Requirements: Flutter SDK, Android SDK/NDK, Rust toolchain, and Android Rust targets.

```sh
flutter pub get
MOSIX_RUST_ANDROID_ABIS=arm64-v8a,armeabi-v7a MOSIX_DISCORD_SDK=0 ./scripts/build_android.sh --lite
```

Release APKs are written under `build/app/outputs/flutter-apk/`.

## Project layout

- `lib/` — Flutter application
- `rust_backend/` — Rust backend and provider integrations
- `android/`, `ios/` — native platform bridges
- `assets/readme/` — screenshots used in this README
- `third_party/` — bundled Flutter plugins and their required notices

## Maintainer

**ZuanCrisp**

## License

Mosix is distributed under LGPL-3.0-only, with the incorporated GPL-3.0 terms. See [LICENSE](LICENSE), [COPYING](COPYING), and [NOTICE](NOTICE). Third-party components retain their own licenses and notices.
