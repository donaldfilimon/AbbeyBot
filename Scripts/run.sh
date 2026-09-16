#!/usr/bin/env bash
# Launch the signed AbbeyBot.app through LaunchServices.
# Server, CLI, and help keep using the raw SwiftPM wrapper.
# Detached: bash Scripts/run.sh --detach   (or ABBEY_DETACH=1)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# `open` hands the app to launchd, which does NOT inherit this shell's
# environment — so exporting .env here is not enough on its own. Collect the
# names it defines and forward each explicitly with `open --env` below.
OPEN_ENV_ARGS=()
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
  while IFS= read -r env_name; do
    [[ -n "$env_name" ]] || continue
    OPEN_ENV_ARGS+=(--env "$env_name=${!env_name-}")
  done < <(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' \
    "$ROOT/.env" | sort -u)
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
  /usr/bin/open -n ${OPEN_ENV_ARGS[@]+"${OPEN_ENV_ARGS[@]}"} "$APP_PATH"
  echo "LAUNCHED app=$APP_PATH"
  exit 0
fi

bash "$ROOT/Scripts/build-macos-app.sh"
APP_PATH="${ABBEY_APP_OUTPUT_PATH:-${ABBEY_APP_BUILD_PATH:-${TMPDIR:-/tmp}/AbbeyBot.app.build}/AbbeyBot.app}"
echo "Launching AbbeyBot.app through LaunchServices. Ctrl+C stops waiting."
exec /usr/bin/open -n -W ${OPEN_ENV_ARGS[@]+"${OPEN_ENV_ARGS[@]}"} "$APP_PATH"
