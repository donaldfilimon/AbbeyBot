#!/usr/bin/env bash
# Launch AbbeyBot desktop with Xcode toolchain (never swiftly / DEVELOPMENT-SNAPSHOT).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
exec /usr/bin/xcrun --toolchain default swift run --build-path "${TMPDIR:-/tmp}/AbbeyBot.build" AbbeyBot
