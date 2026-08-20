#!/usr/bin/env bash
# Server-graph snapshot parity gate.
#
# Builds and tests the SERVER package graph (ABBEY_PACKAGE_ROLE=server — no
# AppKit/SwiftUI/SwiftData) under a swiftly-managed Swift development snapshot,
# mirroring the Linux CI job in .github/workflows/abbey-ci.yml as closely as
# macOS permits: resolve, `swift build --product AbbeyBot`, then the four CI
# test filters (AbbeyServerKitTests with DATABASE_URL=sqlite://memory; the
# other three deliberately without DATABASE_URL, exactly like CI).
#
# This script NEVER changes the swiftly global default and NEVER touches the
# repo's `.swift-version` (which is `xcode` — the desktop target depends on
# it). The snapshot is selected per-invocation only, via swiftly's `+toolchain`
# selector. Desktop work must never use snapshot toolchains (SwiftData macros
# break); use Scripts/swift-run.sh / run-smoke.sh for that path.
#
# Toolchain selection: newest installed `main-snapshot-*` by default; override
# with ABBEY_SNAPSHOT_TOOLCHAIN=<selector> (e.g. main-snapshot-2026-08-11 or a
# 6.5-snapshot-* once installed). Fails loudly if swiftly or the snapshot is
# missing — install one with: swiftly install main-snapshot
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# TOOLCHAINS=swift would drag toolchain resolution sideways; swiftly's +selector
# is the only selection mechanism we want active here.
unset TOOLCHAINS || true

command -v swiftly >/dev/null 2>&1 || {
    echo "SERVER_SNAPSHOT_FAIL: swiftly not found on PATH." >&2
    echo "  Install swiftly (https://www.swift.org/swiftly/) or run the Docker CI image instead." >&2
    exit 69
}

TOOLCHAIN="${ABBEY_SNAPSHOT_TOOLCHAIN:-}"
if [[ -z "$TOOLCHAIN" ]]; then
    # Newest installed main-snapshot (dates sort lexicographically).
    TOOLCHAIN="$(swiftly list 2>/dev/null | grep -Eo '^(main|[0-9]+\.[0-9]+)-snapshot-[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort | tail -1 || true)"
fi
if [[ -z "$TOOLCHAIN" ]]; then
    echo "SERVER_SNAPSHOT_FAIL: no development snapshot toolchain installed in swiftly." >&2
    echo "  Install one with: swiftly install main-snapshot   (does not change the global default)" >&2
    exit 69
fi
if ! swiftly list 2>/dev/null | grep -qF "$TOOLCHAIN"; then
    echo "SERVER_SNAPSHOT_FAIL: requested snapshot '$TOOLCHAIN' is not installed in swiftly." >&2
    echo "  Install it with: swiftly install $TOOLCHAIN" >&2
    exit 69
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${ABBEY_SNAPSHOT_LOG_DIR:-${TMPDIR:-/tmp}/AbbeyBot.server-snapshot-logs/$STAMP}"
SCRATCH="${ABBEY_SNAPSHOT_BUILD_DIR:-${TMPDIR:-/tmp}/AbbeyBot.server-snapshot.build}"
mkdir -p "$LOG_DIR"

echo "SERVER_SNAPSHOT toolchain: $TOOLCHAIN"
echo "SERVER_SNAPSHOT scratch:   $SCRATCH"
echo "SERVER_SNAPSHOT logs:      $LOG_DIR"
swiftly run swift --version "+$TOOLCHAIN" 2>&1 | sed 's/^/  /'

FAILED=0

# run_gate <name> <extra-env...> -- <swift args...>
run_gate() {
    local name="$1"; shift
    local -a extra_env=()
    while [[ "$1" != "--" ]]; do
        extra_env+=("$1")
        shift
    done
    shift
    local log="$LOG_DIR/$name.log"
    echo "== GATE $name =="
    # CI passes only ABBEY_PACKAGE_ROLE (plus DATABASE_URL for ServerKit) into
    # the container; scrub DATABASE_URL here unless the gate re-adds it.
    env -u DATABASE_URL ABBEY_PACKAGE_ROLE=server ${extra_env[@]+"${extra_env[@]}"} \
        swiftly run swift "$@" --scratch-path "$SCRATCH" "+$TOOLCHAIN" \
        >"$log" 2>&1
    local rc=$?
    echo "GATE $name EXIT: $rc (log: $log)"
    if [[ $rc -ne 0 ]]; then
        FAILED=1
        tail -40 "$log" | sed 's/^/  | /'
    else
        # Surface the test-summary lines so counts are visible without opening the log.
        grep -Eh '(Test run with|Suite .* (passed|failed)|Executed [0-9]+ tests?|tests? passed after)' "$log" | tail -4 | sed 's/^/  | /' || true
    fi
    return $rc
}

run_gate resolve            -- package resolve                          || true
if [[ $FAILED -ne 0 ]]; then echo "SERVER_SNAPSHOT_FAIL: resolve failed"; exit 1; fi

run_gate build              -- build --product AbbeyBot                 || true
if [[ $FAILED -ne 0 ]]; then echo "SERVER_SNAPSHOT_FAIL: build failed"; exit 1; fi

run_gate test-core          -- test --filter AbbeyCoreTests             || true
run_gate test-cli           -- test --filter AbbeyCLITests              || true
run_gate test-serverkit DATABASE_URL=sqlite://memory \
                            -- test --filter AbbeyServerKitTests        || true
run_gate test-server        -- test --filter AbbeyServerTests           || true

if [[ $FAILED -ne 0 ]]; then
    echo "SERVER_SNAPSHOT_FAIL: one or more gates failed (logs: $LOG_DIR)"
    exit 1
fi
echo "SERVER_SNAPSHOT_GREEN ($TOOLCHAIN)"
