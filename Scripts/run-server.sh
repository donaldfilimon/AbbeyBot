#!/usr/bin/env bash
# Launch AbbeyServer. Default toolchain: Xcode. For global swiftly:
#   ABBEY_SWIFT=swiftly bash Scripts/run-server.sh
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
if [[ -z "${DATABASE_URL:-}" ]]; then
  if command -v docker >/dev/null 2>&1 \
    && docker compose exec -T db pg_isready -U abbey -d abbeybot >/dev/null 2>&1; then
    export DATABASE_URL="postgres://abbey:abbey@127.0.0.1:5432/abbeybot"
  else
    export DATABASE_URL="sqlite://${TMPDIR:-/tmp}/abbey-server.sqlite"
    echo "DATABASE_URL unset and Postgres unavailable; using $DATABASE_URL" >&2
  fi
fi
HOST="${HTTP_HOSTNAME:-127.0.0.1}"
PORT="${HTTP_PORT:-8080}"
abbey_swift_run server AbbeyServer -- serve --hostname "$HOST" --port "$PORT"
