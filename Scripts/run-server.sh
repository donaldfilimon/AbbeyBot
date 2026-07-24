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
# Match smoke behavior: when DATABASE_URL is unset, prefer compose Postgres if healthy,
# otherwise let AbbeyServerKit fall back to a temp sqlite file (do not leave a dead
# postgres:// default that traps on boot).
if [[ -z "${DATABASE_URL:-}" ]]; then
  if command -v docker >/dev/null 2>&1 \
    && docker compose exec -T db pg_isready -U abbey -d abbeybot >/dev/null 2>&1; then
    export DATABASE_URL="postgres://abbey:abbey@127.0.0.1:5432/abbeybot"
  fi
fi
HOST="${HTTP_HOSTNAME:-127.0.0.1}"
PORT="${HTTP_PORT:-8080}"
exec /usr/bin/xcrun --toolchain default swift run --build-path "${TMPDIR:-/tmp}/AbbeyBot.server.build" AbbeyServer -- serve --hostname "$HOST" --port "$PORT"
