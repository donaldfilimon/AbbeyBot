#!/usr/bin/env bash
# Launch AbbeyServer with Xcode toolchain. Requires DATABASE_URL (see .env.example).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
HOST="${HTTP_HOSTNAME:-127.0.0.1}"
PORT="${HTTP_PORT:-8080}"
exec /usr/bin/xcrun --toolchain default swift run AbbeyServer --build-path "${TMPDIR:-/tmp}/AbbeyBot.server.build" -- serve --hostname "$HOST" --port "$PORT"
