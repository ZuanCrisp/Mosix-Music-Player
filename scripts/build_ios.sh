#!/usr/bin/env bash
# Build the Rust backend XCFramework used by Mornye on iOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/build_rust_backend.sh" ios
