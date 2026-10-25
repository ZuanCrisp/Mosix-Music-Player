# Rustix Android compatibility patch

`rustix-1.1.5` is vendored from the pinned crates.io package using `cargo vendor`.
Its upstream license files are retained. Cargo's workspace patch applies to both
direct users and transitive dependencies such as `cap-std`.
The original package checksum is
`891efababe418670775f199f0d233d84843c227a0949a883ce15b37c78d6629d`.

The sole upstream source change is in `src/backend/libc/fs/syscalls.rs`: Android
uses `weakcall!` for `statx`, rather than `weak_or_syscall!`. Bionic exports this
function from API 30. On earlier releases, probing the raw syscall can terminate
the app with `SIGSYS/SYS_SECCOMP` instead of returning an error (observed on
Android 10 ARM32, syscall 397 during `read_audio_metadata`). Missing symbols now
return `ENOSYS`, allowing the existing `fstat64`/`fstatat64` fallback. Newer Android
continues to use Bionic's `statx`; non-Android targets retain upstream behavior.

References:
- [Bionic stat.h](https://android.googlesource.com/platform/bionic/+/refs/heads/main/libc/include/sys/stat.h)
- [Upstream Rustix](https://github.com/bytecodealliance/rustix)

When upgrading Rustix, check whether upstream has fixed this path before removing
the patch. Keep the Android metadata smoke test and verify both APK ABIs.

Run `bash scripts/check_android_statx.sh arm64-v8a` (or `armeabi-v7a`) with
`ANDROID_NDK_HOME` set and a matching Android device connected through `adb`.
The isolated test executable checks regular metadata access, then hides the libc
symbol and blocks the raw syscall to exercise the legacy fallback. A final probe
deliberately exits with `SIGSYS` to verify that the filter is active. Neither the
symbol wrapper nor the filter is included in the application. This simulated
sandbox check complements testing the APK on an actual older ARM32 device.

# libusb native source update

`libusb1-sys-0.7.0` is the latest stable Rust binding. Its upstream bundle is
libusb 1.0.27, so the workspace patch replaces the C source directory and MSVC
configuration with the official libusb 1.0.30 release. The Rust API and bindings
are unchanged; `build.rs` reports 1.0.30 when compiling the vendored C library.
The Android dependency keeps its `vendored` feature, so both APK ABIs use these
sources instead of an arbitrary host installation. Upstream licenses are retained.

Source: https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2
SHA-256: `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf`

The `.cargo-checksum.json` file lists the updated local source hashes while
retaining the original registry package checksum as provenance. The same applies
to the Rustix compatibility patch above.
