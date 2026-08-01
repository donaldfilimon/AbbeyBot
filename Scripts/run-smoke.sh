#!/usr/bin/env bash
# Desktop smoke for AbbeyBot (macOS 27 / .macOS(.v27)).
# Always uses Xcode toolchain via xcrun — never PATH/swiftly DEVELOPMENT-SNAPSHOT.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
# Full package graph (SwiftUI/SwiftData) — never build desktop under server-only role.
unset ABBEY_PACKAGE_ROLE || true
# Build off Desktop to avoid iCloud/Finder xattrs breaking ad-hoc codesign.
BUILD_PATH="${TMPDIR:-/tmp}/AbbeyBot.build"
SWIFT=(/usr/bin/xcrun --toolchain default swift)

echo "======== 1/4 debug build (macOS 27) ========"
"${SWIFT[@]}" build --build-path "$BUILD_PATH"

echo "======== 2/4 release build ========"
"${SWIFT[@]}" build -c release --build-path "$BUILD_PATH"

echo "======== 3/4 all Swift test targets ========"
# The desktop graph contains all five test bundles. Running without a filter prevents the
# release gate from silently omitting app, CLI, server-kit, or HTTP route tests.
"${SWIFT[@]}" test --build-path "$BUILD_PATH"

echo "======== 4/4 app launch ========"
BIN="$BUILD_PATH/out/Products/Debug/AbbeyBot"
if [[ ! -x "$BIN" ]]; then
  BIN="$(find "$BUILD_PATH" -name AbbeyBot -type f -perm +111 | head -1)"
fi
test -x "$BIN"
# Isolate UserDefaults from host Settings (e.g. remoteCompatible without endpoint).
SMOKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/abbey-smoke-home.XXXXXX")"
mkdir -p "$SMOKE_HOME/Library/Preferences"
HOME="$SMOKE_HOME" ABBEY_DRY_RUN=1 ABBEY_INFERENCE_MODE=deterministicFloor "$BIN" >/tmp/abbeybot-launch.log 2>&1 &
PID=$!
sleep 2
if kill -0 "$PID" 2>/dev/null; then
  echo "LAUNCH_OK pid=$PID"
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  rm -rf "$SMOKE_HOME"
else
  echo "LAUNCH_FAILED"
  cat /tmp/abbeybot-launch.log || true
  rm -rf "$SMOKE_HOME"
  exit 1
fi

echo
echo "======== ALL GATES GREEN ========"
