#!/usr/bin/env bash
# Launch AbbeyBot desktop with Xcode toolchain (never swiftly / DEVELOPMENT-SNAPSHOT).
# After build, the GUI stays attached — silence is normal. Ctrl+C quits (exit 130).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
echo "Launching AbbeyBot GUI (attached). Ctrl+C quits the app (exit 130)."
exec /usr/bin/xcrun --toolchain default swift run --build-path "${TMPDIR:-/tmp}/AbbeyBot.build" AbbeyBot
