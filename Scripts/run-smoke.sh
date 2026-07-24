#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
# Build off Desktop to avoid iCloud/Finder xattrs breaking ad-hoc codesign.
BUILD_PATH="${TMPDIR:-/tmp}/AbbeyBot.build"
SWIFT=(/usr/bin/xcrun --toolchain default swift)

echo "======== 1/4 debug build ========"
"${SWIFT[@]}" build --build-path "$BUILD_PATH"

echo "======== 2/4 release build ========"
"${SWIFT[@]}" build -c release --build-path "$BUILD_PATH"

echo "======== 3/4 tests ========"
"${SWIFT[@]}" test --filter AbbeyCoreTests --build-path "$BUILD_PATH"

echo "======== 4/4 app launch ========"
BIN="$BUILD_PATH/out/Products/Debug/AbbeyBot"
if [[ ! -x "$BIN" ]]; then
  BIN="$(find "$BUILD_PATH" -name AbbeyBot -type f -perm +111 | head -1)"
fi
test -x "$BIN"
"$BIN" >/tmp/abbeybot-launch.log 2>&1 &
PID=$!
sleep 2
if kill -0 "$PID" 2>/dev/null; then
  echo "LAUNCH_OK pid=$PID"
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
else
  echo "LAUNCH_FAILED"
  cat /tmp/abbeybot-launch.log || true
  exit 1
fi

echo
echo "======== ALL GATES GREEN ========"
