#!/usr/bin/env bash
# Dashboard gate: dependency lock, lint, tests, production build, and packed resource assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v bun >/dev/null 2>&1; then
  echo "WEB_SMOKE_FAIL: bun is required (https://bun.sh)" >&2
  exit 1
fi

echo "======== web 1/5 install frozen dependencies ========"
cd web
bun install --frozen-lockfile

echo "======== web 2/5 lint ========"
bun run lint

echo "======== web 3/5 tests ========"
bun run test

echo "======== web 4/5 production build ========"
bun run build

echo "======== web 5/5 packed resource ========"
test -f "$ROOT/Sources/AbbeyServer/Resources/Public/index.html"

echo
echo "======== WEB SMOKE GREEN ========"
