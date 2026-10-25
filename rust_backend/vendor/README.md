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

# cap-primitives Windows UNC compatibility patch

`cap-primitives-4.0.3` is vendored from the pinned crates.io package using
`cargo vendor`, with its upstream licenses retained. The original package checksum
is `8b5f74729fd2f44701d1a8eb47e906cdb3ccd9ec0f02baad85a744b791940b18`.
The workspace patch applies to every `cap-std` directory capability.

Upstream `src/windows/fs/get_path.rs` strips four characters from every extended
path returned by a Windows handle. For network shares this changes
`\\?\UNC\server\share` into the relative path `UNC\server\share`, breaking directory
enumeration, rename, and other operations that reconstruct a pathname. The local
`path_prefix.rs` helper converts it to `\\server\share` instead, retains UTF-16
names, and preserves device namespaces that cannot be converted to DOS paths.
Local drive paths keep their existing conversion. Other platforms are unchanged.
The unused upstream `Cow` import in `src/fs/manually/open.rs` is also removed
because local path dependencies expose that warning during application builds.

The application also uses `MoveFileExW` without `REPLACE_EXISTING` to publish new
downloads on Windows, instead of depending on filesystem hard-link support.
It gets both verbatim paths from the opened parent directory and retains the
existing cancellation, collision, and staging cleanup behavior.

Run `cargo test -p mornye-extensions --test windows_path_prefix` on any host for
the production prefix conversion tests, and
`cargo test -p mornye-extensions --lib files::tests` for file lifecycle tests.
Windows additionally exercises paths beyond `MAX_PATH`. For a real SMB share,
run these commands in PowerShell from `rust_backend`:

```powershell
$env:MORNYE_TEST_SMB_ROOT = '\\server\share\writable-test-folder'
cargo test -p mornye-extensions windows_network_share_directory_operations -- --ignored
$env:MORNYE_TEST_SMB_ROOT = 'Z:\writable-test-folder'
cargo test -p mornye-extensions windows_network_share_directory_operations -- --ignored
```

The test creates and removes its own temporary directory within the supplied
folder. Use a mapped drive pointing to the same share for the second run. These
checks require Windows with access to that share; host tests do not establish
SMB compatibility. Check upstream before removing this patch during an upgrade.

References:
- [Reported desktop issue](https://github.com/mornyeapp/Mornye-Desktop/issues/3)
- [Upstream get_path](https://github.com/bytecodealliance/cap-std/blob/main/cap-primitives/src/windows/fs/get_path.rs)
- [MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
