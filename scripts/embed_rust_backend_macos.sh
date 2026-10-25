#!/usr/bin/env bash
# Xcode Run Script phase of the macOS Runner target ("Embed Rust Backend").
# Copies the Rust desktop backend (libmornye_desktop.dylib) into
# <App>.app/Contents/Frameworks, where dart:ffi loads it, and signs it.
#
# The library is built with `bash scripts/build_rust_backend.sh desktop` when
# the staged copy is missing or older than the Rust sources. Set
# MORNYE_SKIP_RUST_BUILD=1 to embed a prebuilt staged library as is (CI builds
# it in an earlier step); the app build then fails if none is staged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUST_BACKEND_DIR="$PROJECT_DIR/rust_backend"
LIBRARY_NAME="libmornye_desktop.dylib"
STAGED_LIBRARY="$RUST_BACKEND_DIR/target/desktop/macos/$LIBRARY_NAME"

: "${TARGET_BUILD_DIR:?Run this script from the Xcode build of the macOS Runner target.}"
: "${FRAMEWORKS_FOLDER_PATH:?Run this script from the Xcode build of the macOS Runner target.}"

library_is_stale() {
  [[ ! -f "$STAGED_LIBRARY" ]] && return 0
  local newer
  newer="$(find \
    "$RUST_BACKEND_DIR/crates" \
    "$RUST_BACKEND_DIR/vendor" \
    "$RUST_BACKEND_DIR/Cargo.toml" \
    "$RUST_BACKEND_DIR/Cargo.lock" \
    "$RUST_BACKEND_DIR/rust-toolchain.toml" \
    "$SCRIPT_DIR/build_rust_backend.sh" \
    -type f -newer "$STAGED_LIBRARY" -print -quit 2>/dev/null || true)"
  [[ -n "$newer" ]]
}

if [[ "${MORNYE_SKIP_RUST_BUILD:-0}" == "1" ]]; then
  if [[ ! -f "$STAGED_LIBRARY" ]]; then
    echo "error: MORNYE_SKIP_RUST_BUILD=1 but $STAGED_LIBRARY is missing. Run: bash scripts/build_rust_backend.sh desktop" >&2
    exit 1
  fi
elif library_is_stale; then
  echo "Building the Rust desktop backend (set MORNYE_SKIP_RUST_BUILD=1 to use a prebuilt library)."
  # Xcode's environment does not include rustup's default location.
  if ! command -v cargo >/dev/null 2>&1; then
    export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
  fi
  # Use the build script's defaults instead of the Runner target's settings, so
  # Xcode and command line builds share Cargo's cache.
  if ! env -u MACOSX_DEPLOYMENT_TARGET -u SDKROOT \
    bash "$SCRIPT_DIR/build_rust_backend.sh" desktop; then
    echo "error: building the Rust desktop backend failed (see the log above)." >&2
    exit 1
  fi
fi

DESTINATION_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DESTINATION_DIR"
cp -f "$STAGED_LIBRARY" "$DESTINATION_DIR/$LIBRARY_NAME"

# Nested code must be signed before Xcode signs the app. The app ships
# unsigned for now (ad hoc, "-"); a configured identity is used when present.
SIGN_IDENTITY="-"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$EXPANDED_CODE_SIGN_IDENTITY"
fi
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  "$DESTINATION_DIR/$LIBRARY_NAME"
echo "Embedded $LIBRARY_NAME in $DESTINATION_DIR (signed with identity $SIGN_IDENTITY)."
