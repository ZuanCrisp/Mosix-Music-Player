# iOS FFmpeg capability probe

`scripts/ios_ffmpeg_capabilities.m` runs the shipped simulator frameworks without
building the Flutter app. It checks FLAC, ALAC, 24-bit WAV/AIFF, MP3, Opus and AAC
encoding/decoding; analysis filters; spectrum PNG/JPEG conversion; and H.264/HEVC
motion decoding and stream-copy remuxing. This complements application tests: it
does not prove Flutter routing, download finalization or the Dart TLS proxy.

Prepare the audio plugin's XCFrameworks with its provided `scripts/setup_ios.sh`
from the plugin's `ios` directory. Boot an iOS simulator, then run the following
from the repository root. Framework copies are signed in a temporary directory;
the downloaded vendor artifacts remain unchanged.

```bash
probe_plugin="$HOME/.pub-cache/hosted/pub.dev/ffmpeg_kit_flutter_new_audio-2.5.7"
probe_work=$(mktemp -d /tmp/mornye-ios-ffmpeg.XXXXXX)
mkdir -p "$probe_work/Frameworks"
for framework in "$probe_plugin"/ios/Frameworks/*.xcframework; do
    name=$(basename "$framework" .xcframework)
    cp -R "$framework/ios-arm64_x86_64-simulator/$name.framework" "$probe_work/Frameworks/"
    codesign --force --sign - "$probe_work/Frameworks/$name.framework"
done
xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios16.0-simulator \
    -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -F "$probe_work/Frameworks" -framework Foundation -framework ffmpegkit \
    -Wl,-rpath,"$probe_work/Frameworks" scripts/ios_ffmpeg_capabilities.m \
    -o "$probe_work/probe"
codesign --force --sign - "$probe_work/probe"
xcrun simctl spawn booted "$probe_work/probe" "$probe_work/results" \
    "$PWD/android/app/src/androidTest/assets"
```

The audio package exposes HTTP but has no native HTTPS/TLS support. Remote motion
input requires the app's scoped Dart TLS proxy. To exercise remote input, append
a fixture URL as the last probe argument; use the proxy's HTTP loopback URL when
testing the application route. Passing a direct HTTPS URL intentionally reports
a capability failure on this package. Run the proxy's Dart tests and Android/iOS
application checks before claiming that remote motion playback is preserved.

Remote checks decode the complete fixture, stream-copy it to MP4 with faststart,
and decode the resulting MP4 with strict error handling. The probe also prints
the shipped HLS demuxer's options. For HLS fixtures with opaque segment URLs,
append `--disable-hls-extension-check` after the proxy URL; this passes
`-extension_picky 0` only for that input. The other HLS flags in the usage message
are diagnostic modes for comparing the native extension checks.

Verified on the shipped iOS simulator audio frameworks:

| HTTPS-origin fixture through the Dart proxy | Input options | Decode/remux/decode |
| --- | --- | --- |
| Redirected master playlist, AES-128 key, three TS segments | Defaults | Pass |
| Same content with `.bin`, extensionless and `.ts` segment URLs | Defaults | Rejects segment extension |
| Same opaque segment URLs | `-allowed_extensions ALL` | Rejects segment extension |
| Same opaque segment URLs | Both extension lists set to `ALL` | Rejects format/extension mismatch |
| Same opaque segment URLs | `-extension_picky 0` | Pass |

The app uses the final option for scoped HLS proxy input. The proxy still owns
the upstream URL allowlist, TLS requests, transfer budget and cancellation.
