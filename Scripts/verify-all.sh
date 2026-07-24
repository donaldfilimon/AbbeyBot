#!/usr/bin/env bash
# Run desktop + server smoke gates sequentially.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
bash Scripts/run-smoke.sh
bash Scripts/run-server-smoke.sh
echo
echo "======== VERIFY-ALL GREEN ========"
