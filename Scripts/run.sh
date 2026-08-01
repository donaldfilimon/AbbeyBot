#!/usr/bin/env bash
# Launch the signed AbbeyBot.app through LaunchServices.
# Server, CLI, and help keep using the raw SwiftPM wrapper.
# Detached: bash Scripts/run.sh --detach   (or ABBEY_DETACH=1)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

case "${1:-}" in
  serve|cli|help)
    exec bash "$ROOT/Scripts/swift-run.sh" "$@"
    ;;
esac

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
  bash "$ROOT/Scripts/build-macos-app.sh"
  APP_PATH="${ABBEY_APP_OUTPUT_PATH:-${ABBEY_APP_BUILD_PATH:-${TMPDIR:-/tmp}/AbbeyBot.app.build}/AbbeyBot.app}"
  /usr/bin/open -n "$APP_PATH"
  echo "LAUNCHED app=$APP_PATH"
  exit 0
fi

bash "$ROOT/Scripts/build-macos-app.sh"
APP_PATH="${ABBEY_APP_OUTPUT_PATH:-${ABBEY_APP_BUILD_PATH:-${TMPDIR:-/tmp}/AbbeyBot.app.build}/AbbeyBot.app}"
echo "Launching AbbeyBot.app through LaunchServices. Ctrl+C stops waiting."
exec /usr/bin/open -n -W "$APP_PATH"
