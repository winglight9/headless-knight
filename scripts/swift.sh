#!/bin/bash
# `swift` with the CLT manifest workaround applied.
#   scripts/swift.sh build -c release
#   scripts/swift.sh test
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build-toolchain"

if [ ! -x "$OUT/swiftc" ]; then
    "$ROOT/scripts/fix-swiftpm.sh" >/dev/null
fi

# SwiftPM's own sandbox cannot nest inside the sandbox that hosts this build.
SANDBOX_FLAG=""
case "${1:-}" in
    build|test|run) SANDBOX_FLAG="--disable-sandbox" ;;
esac

SWIFT_EXEC="$OUT/swiftc" swift "$@" $SANDBOX_FLAG
