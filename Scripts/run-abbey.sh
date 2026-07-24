#!/usr/bin/env bash
# Launch abbey CLI. Default toolchain: Xcode. For global swiftly:
#   ABBEY_SWIFT=swiftly bash Scripts/run-abbey.sh
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
abbey_swift_run cli abbey
