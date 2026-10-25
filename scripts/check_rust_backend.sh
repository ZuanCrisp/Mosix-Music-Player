#!/usr/bin/env bash
# Check the production Rust workspace without local migration archives.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check_rust_backend.sh

  Run Rust formatting, Clippy, and unit tests.
  --help    Show this help text.
EOF
}

if (( $# > 1 )); then
  echo "Error: unexpected arguments: $*" >&2
  usage >&2
  exit 2
fi
if (( $# == 1 )); then
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR/rust_backend"
# AES 0.9 uses the same runtime-detected backend as the release build.
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
