#!/usr/bin/env bash
# Launch abbey CLI via unified AbbeyBot entry (`swift run AbbeyBot cli`).
# Swiftly: ABBEY_SWIFT=swiftly bash Scripts/run-abbey.sh
#
# Loads .env for DISCORD_* / ABBEY_* knobs, but ignores DATABASE_URL by default so the
# server's Postgres URL does not hijack the local REPL (~/.abbey/abbey.sqlite).
# Opt into sharing the server DB: ABBEY_CLI_USE_SERVER_DATABASE=1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=abbey-swift.sh
source "$ROOT/Scripts/abbey-swift.sh"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
if [[ "${ABBEY_CLI_USE_SERVER_DATABASE:-}" != "1" ]]; then
  if [[ -n "${DATABASE_URL:-}" ]]; then
    echo "CLI: ignoring DATABASE_URL from env (use ABBEY_CLI_USE_SERVER_DATABASE=1 to keep it); defaulting to ~/.abbey/abbey.sqlite" >&2
  fi
  unset DATABASE_URL || true
fi
abbey_swift_run cli cli
