# Local FFmpegKit patch

Based on ffmpeg_kit_flutter_new_audio 2.5.7 (license retained in LICENSE).
The upstream `example` app is not copied.

The root `pubspec.yaml` overrides the package with this copy
(`dependency_overrides: ffmpeg_kit_flutter_new_audio: path:
third_party/ffmpeg_kit_flutter_new_audio`), next to the pinned
`ffmpeg_kit_flutter_new_audio: 2.5.7`. The version is the one in this
folder's `pubspec.yaml` (2.5.7, unchanged).

## Patches

### Linux architectures without a bundle

Upstream publishes Linux bundles for x86_64 only, and `linux/CMakeLists.txt`
stopped the build with a fatal error on any other architecture, so the app
could not be built for Linux arm64 at all.

On an architecture without a bundle, and with no `FFMPEGKIT_LOCAL_DIR`, the
plugin is now built without `libffmpegkit.so` and a CMake warning says so.
The plugin already loads the library with `dlopen()` and answers every call
with an error when it is missing. Mornye desktop never calls FFmpegKit's
native layer: it runs the bundled `ffmpeg` and `ffprobe` executables
(`lib/services/ffmpeg_desktop.dart` in the app) and uses only the package's
Dart code (argument parsing and the media information model).

x86_64 builds and builds with `FFMPEGKIT_LOCAL_DIR` keep upstream behavior.
