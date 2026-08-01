#!/usr/bin/env bash
# Release authority: static/security hygiene, dashboard, all Swift tests, and executable smokes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
# Desktop graph must not inherit a leftover server-only role from a prior smoke.
unset ABBEY_PACKAGE_ROLE || true
bash Scripts/check-static-security.sh
bash Scripts/run-web-smoke.sh
bash Scripts/run-smoke.sh
bash Scripts/run-server-smoke.sh
bash Scripts/run-cli-smoke.sh
echo
echo "======== VERIFY-ALL GREEN ========"
