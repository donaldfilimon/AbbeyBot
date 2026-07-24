#!/usr/bin/env bash
# Launch AbbeyBot desktop with Xcode toolchain (never swiftly / DEVELOPMENT-SNAPSHOT).
# After build, the GUI stays attached to this terminal — that silence is normal, not a hang.
# Ctrl+C quits the app (shell exit 130). For a detach-and-return-0 launch: ABBEY_DETACH=1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
BUILD_PATH="${TMPDIR:-/tmp}/AbbeyBot.build"
SWIFT=(/usr/bin/xcrun --toolchain default swift)

"${SWIFT[@]}" build --product AbbeyBot --build-path "$BUILD_PATH"
BIN="$BUILD_PATH/debug/AbbeyBot"
if [[ ! -x "$BIN" ]]; then
  BIN="$(find "$BUILD_PATH" -name AbbeyBot -type f -perm +111 | head -1)"
fi
test -x "$BIN"

if [[ "${ABBEY_DETACH:-}" == "1" ]]; then
  LOG="${TMPDIR:-/tmp}/abbeybot-run.log"
  "$BIN" >"$LOG" 2>&1 &
  echo "AbbeyBot launched (pid $!, log $LOG). Terminal is free."
  exit 0
fi

echo "Launching AbbeyBot GUI — window should come to the front."
echo "This terminal stays attached on purpose. Ctrl+C quits the app (exit 130)."
exec "$BIN"
