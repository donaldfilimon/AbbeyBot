#!/usr/bin/env bash
# Idempotent bootstrap for AbbeyBot (macOS + Xcode toolchain required).
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "AbbeyBot: macOS + Xcode required; skipping build on $(uname -s)."
  exit 0
fi

unset TOOLCHAINS || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Swift toolchain"
/usr/bin/xcrun --toolchain default swift --version

echo "==> swift build (off-Desktop path)"
BUILD_PATH="${TMPDIR:-/tmp}/AbbeyBot.build"
/usr/bin/xcrun --toolchain default swift build --build-path "$BUILD_PATH"

echo "==> AbbeyBot install OK"
