#!/usr/bin/env bash
# Launch abbey terminal chat CLI with Xcode toolchain. Local SQLite by default (see .env.example).
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
exec /usr/bin/xcrun --toolchain default swift run --build-path "${TMPDIR:-/tmp}/AbbeyBot.cli.build" abbey
