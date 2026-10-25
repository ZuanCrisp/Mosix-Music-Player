#!/usr/bin/env bash
# Exercise statx fallback without requiring an old Android system image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
case "${1:-arm64-v8a}" in
  arm64-v8a) target=aarch64-linux-android; compiler=aarch64-linux-android24-clang ;;
  armeabi-v7a) target=armv7-linux-androideabi; compiler=armv7a-linux-androideabi24-clang ;;
  *) echo "Usage: $0 [arm64-v8a|armeabi-v7a]" >&2; exit 2 ;;
esac
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME}"
case "$(uname -s)" in
  Darwin) ndk_host=darwin-x86_64 ;;
  Linux) ndk_host=linux-x86_64 ;;
  *) exit 2 ;;
esac
ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$ndk_host/bin"
target_env="${target//-/_}"
linker_env="$(printf '%s' "$target_env" | tr '[:lower:]' '[:upper:]')"
export "CARGO_TARGET_${linker_env}_LINKER=$ndk_bin/$compiler"
export "CC_${target_env}=$ndk_bin/$compiler"
export "AR_${target_env}=$ndk_bin/llvm-ar"
export "BINDGEN_EXTRA_CLANG_ARGS_${target_env}=--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$ndk_host/sysroot --target=${compiler%-clang}"
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384"

cd "$PROJECT_DIR/rust_backend"
cargo rustc --locked --release -p spotiflac-extensions --example android_statx_smoke \
  --target "$target" -- -C link-arg=-Wl,--wrap=dlsym
remote="/data/local/tmp/spotiflac-statx-smoke-$$"
trap 'adb shell rm -f "$remote" >/dev/null 2>&1 || true' EXIT
adb push "target/$target/release/examples/android_statx_smoke" "$remote"
adb shell chmod 700 "$remote"
adb shell "$remote"
adb shell "$remote --legacy"
set +e
adb shell "$remote --probe-blocked-syscall"
status=$?
set -e
if [[ "$status" != 159 ]]; then
  echo "Expected SIGSYS (159) from the isolated filter probe, got $status" >&2
  exit 1
fi
echo "Android statx compatibility smoke test passed."
