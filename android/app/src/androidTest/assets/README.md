# Synthetic DSD fixture

`dsd-pattern.wv` is original test data, not a music recording. WavPack 5.9.0
encoded a stereo DSD64 DSF with 16,384 bytes per channel and 4,096-byte channel
blocks. Normalized MSB-first byte `i` of channel `c` is `(i * 17 + c * 29) & 255`.
The DSF input stores those bytes with reversed bits (LSB-first).

This tests lossless WavPack DSD decoding, channel order, seek alignment, native
LE/BE packing and DoP packing against known bytes. It is packaged only in the
instrumentation test APK.

## Synthetic motion artwork fixtures

`motion-probe-h264.mp4` and `motion-probe-hevc.mp4` contain one second of the
FFmpeg `testsrc2` pattern at 32x32 pixels and two frames per second. They are
original generated test data and are packaged only in the instrumentation APK.
The capability test validates decoding and MP4 stream-copy after reducing the
shipped FFmpeg dependency. Generate with `-f lavfi -i testsrc2=size=32x32:rate=2
-t 1 -an -pix_fmt yuv420p -movflags +faststart`, using `-c:v libx264` or
`-c:v libx265 -x265-params log-level=error:pools=1 -tag:v hvc1` respectively.

For a live encrypted HLS gate through `MotionArtworkProxy`, forward its local
port with `adb reverse tcp:PORT tcp:PORT` and pass
`-e motionProxyUrl http://127.0.0.1:PORT/TOKEN/0.m3u8` to the instrumentation
runner for `com.zuancrisp.mosix.FFmpegCapabilitiesTest`. The optional gate decodes
the input, remuxes it, then decodes the resulting MP4 using the shipped native
library. Normal fixture tests run without a server or this argument.
