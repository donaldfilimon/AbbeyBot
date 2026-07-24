#!/usr/bin/env bash
# Launch AbbeyBot desktop — Xcode toolchain only (never swiftly / DEVELOPMENT-SNAPSHOT).
# After build, the GUI stays attached — silence is normal. Ctrl+C quits (exit 130).
# Equivalent to bare: swift run
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export ABBEY_SWIFT=xcode
# shellcheck source=abbey-swift.sh
source "$ROOT/Scripts/abbey-swift.sh"
echo "Launching AbbeyBot GUI (attached). Ctrl+C quits the app (exit 130)."
abbey_swift_run desktop desktop
