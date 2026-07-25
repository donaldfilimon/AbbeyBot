#!/usr/bin/env bash
# Launch AbbeyBot desktop — Xcode toolchain only (never swiftly / DEVELOPMENT-SNAPSHOT).
# After build, the GUI stays attached — silence is normal. Ctrl+C quits (exit 130).
# Detached: bash Scripts/run.sh --detach   (or ABBEY_DETACH=1)
# Equivalent to bare: swift run
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export ABBEY_SWIFT=xcode
# shellcheck source=abbey-swift.sh
source "$ROOT/Scripts/abbey-swift.sh"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

DETACH=0
if [[ "${ABBEY_DETACH:-0}" == "1" ]]; then
  DETACH=1
fi
for arg in "$@"; do
  case "$arg" in
    --detach) DETACH=1 ;;
    *)
      echo "usage: bash Scripts/run.sh [--detach]" >&2
      exit 2
      ;;
  esac
done

if [[ "$DETACH" -eq 1 ]]; then
  abbey_resolve_swift
  abbey_assert_desktop_toolchain || exit 1
  BUILD_PATH="${TMPDIR:-/tmp}/AbbeyBot.desktop.build"
  unset ABBEY_PACKAGE_ROLE || true
  echo "Building AbbeyBot GUI (detached)…"
  "${ABBEY_SWIFT_BIN[@]}" build --build-path "$BUILD_PATH"
  BIN="$BUILD_PATH/out/Products/Debug/AbbeyBot"
  if [[ ! -x "$BIN" ]]; then
    matches=()
    while IFS= read -r candidate; do
      matches+=("$candidate")
    done < <(find "$BUILD_PATH" -path '*/Debug/AbbeyBot' -type f -perm +111 2>/dev/null)
    if [[ "${#matches[@]}" -eq 1 ]]; then
      BIN="${matches[0]}"
    elif [[ "${#matches[@]}" -gt 1 ]]; then
      echo "error: multiple AbbeyBot binaries under $BUILD_PATH; expected $BUILD_PATH/out/Products/Debug/AbbeyBot" >&2
      printf '  %s\n' "${matches[@]}" >&2
      exit 1
    fi
  fi
  if [[ ! -x "$BIN" ]]; then
    echo "error: AbbeyBot binary not found under $BUILD_PATH" >&2
    exit 1
  fi
  LOG=/tmp/abbeybot-desktop.log
  nohup "$BIN" >"$LOG" 2>&1 &
  PID=$!
  echo "LAUNCHED pid=$PID log=$LOG"
  exit 0
fi

echo "Launching AbbeyBot GUI (attached). Ctrl+C quits the app (exit 130)."
abbey_swift_run desktop desktop
