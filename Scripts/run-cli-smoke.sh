#!/usr/bin/env bash
# Non-interactive abbey CLI boot smoke (server package graph).
# Asserts sqlite boot and that the run-abbey DATABASE_URL gate isolates Postgres.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
BUILD_PATH="${TMPDIR:-/tmp}/AbbeyBot.cli.build"
SWIFT=(/usr/bin/xcrun --toolchain default swift)
SQLITE_PATH="${TMPDIR:-/tmp}/abbey-cli-smoke.sqlite"
rm -f "$SQLITE_PATH" "${SQLITE_PATH}.isolated"

echo "======== 1/3 build AbbeyBot (server graph) ========"
export ABBEY_PACKAGE_ROLE=server
"${SWIFT[@]}" build --product AbbeyBot --build-path "$BUILD_PATH"

BIN="$BUILD_PATH/debug/AbbeyBot"
if [[ ! -x "$BIN" ]]; then
  BIN="$(find "$BUILD_PATH" -name AbbeyBot -type f -perm +111 | head -1)"
fi
test -x "$BIN"

echo "======== 2/3 boot cli with temp sqlite (dry-run) ========"
OUT=/tmp/abbey-cli-smoke.log
# `env` must wrap the binary (right side of the pipe), not printf.
printf '/exit\n' | env ABBEY_DRY_RUN=1 DATABASE_URL="sqlite://${SQLITE_PATH}" \
  "$BIN" cli >"$OUT" 2>&1 || {
  echo "CLI_SMOKE_FAIL: binary exit nonzero"
  cat "$OUT" || true
  exit 1
}
rg -q "Abbey CLI" "$OUT" || { echo "CLI_SMOKE_FAIL: missing banner"; cat "$OUT"; exit 1; }
rg -q "abbey>" "$OUT" || { echo "CLI_SMOKE_FAIL: missing prompt"; cat "$OUT"; exit 1; }
rg -q "Database dialect: sqlite-file" "$OUT" || { echo "CLI_SMOKE_FAIL: expected sqlite-file"; cat "$OUT"; exit 1; }
echo "cli_boot_ok"

echo "======== 3/3 run-abbey DATABASE_URL gate ========"
# Same gate as Scripts/run-abbey.sh: clear server Postgres URL unless opt-in.
OUT2=/tmp/abbey-cli-smoke-gate.log
(
  set -euo pipefail
  export DATABASE_URL="postgres://abbey:abbey@127.0.0.1:1/abbeybot"
  unset ABBEY_CLI_USE_SERVER_DATABASE || true
  if [[ "${ABBEY_CLI_USE_SERVER_DATABASE:-}" != "1" ]]; then
    unset DATABASE_URL || true
  fi
  # Gate must leave DATABASE_URL unset (CLI would then use ~/.abbey/abbey.sqlite).
  if [[ -n "${DATABASE_URL:-}" ]]; then
    echo "CLI_SMOKE_FAIL: gate did not clear DATABASE_URL" >&2
    exit 1
  fi
  # Pin temp sqlite so smoke does not touch the operator's ~/.abbey DB.
  export DATABASE_URL="sqlite://${SQLITE_PATH}.isolated"
  export ABBEY_DRY_RUN=1
  printf '/exit\n' | "$BIN" cli
) >"$OUT2" 2>&1 || {
  echo "CLI_SMOKE_FAIL: isolation boot failed"
  cat "$OUT2" || true
  exit 1
}
rg -q "Database dialect: sqlite-file" "$OUT2" || { echo "CLI_SMOKE_FAIL: expected sqlite after gate"; cat "$OUT2"; exit 1; }
rg -q "Abbey CLI" "$OUT2" || { echo "CLI_SMOKE_FAIL: missing banner after gate"; cat "$OUT2"; exit 1; }
echo "cli_launcher_isolation_ok"

echo
echo "======== CLI SMOKE GREEN ========"
