#!/usr/bin/env bash
# Raw SPM-style launch with Desktop-safe build path + Xcode toolchain.
# Prefer this over bare `swift run` when the tree lives under Desktop/iCloud.
#
#   bash Scripts/swift-run.sh help
#   bash Scripts/swift-run.sh              # desktop
#   bash Scripts/swift-run.sh serve …
#   bash Scripts/swift-run.sh cli
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
unset ABBEY_PACKAGE_ROLE || true
BUILD_PATH="${TMPDIR:-/tmp}/AbbeyBot.build"
exec /usr/bin/xcrun --toolchain default swift run --build-path "$BUILD_PATH" AbbeyBot "$@"
