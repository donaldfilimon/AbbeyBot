#!/usr/bin/env bash
# Local LINUX cross-compile gate for the server graph.
#
# Cross-compiles the SERVER package graph (ABBEY_PACKAGE_ROLE=server — no
# AppKit/SwiftUI/SwiftData) for Linux using a swift.org Static Linux SDK, so a
# "Darwin provides something Linux does not" break is found in minutes on this
# Mac instead of ~18 minutes per Actions round trip.
#
# WHAT THIS IS NOT
# ----------------
# * NOT a test run. The Static Linux SDK ships **no `Testing` and no `XCTest`
#   module** — verified two ways: an unbounded `find` for `*Testing*`/`*XCTest*`
#   over the whole artifact bundle returns nothing, and the module directory
#   (`.../musl-1.2.5.sdk/x86_64/usr/lib/swift_static/linux-static`) contains
#   neither. So `swift build --build-tests` cannot even compile the test
#   targets, let alone run them. Test sources are covered natively by
#   Scripts/check-server-snapshot.sh. The two scripts are COMPLEMENTARY:
#     - check-server-snapshot.sh → macOS host, nightly compiler, builds AND runs
#       the four CI test filters. Catches compiler-version breaks, misses
#       Linux-only ones.
#     - check-server-linux.sh    → real Linux target, product graph only.
#       Catches Linux-only breaks, misses everything in Tests/.
#   Neither one alone predicts CI.
#
# * NOT the same libc as CI. This SDK is **musl**; CI runs
#   `swiftlang/swift:nightly-6.4.x-bookworm`, which is **glibc**. That gap is
#   real and has already bitten once — glibc declares `extern FILE *stderr;`
#   (a mutable global, which Swift 6 strict concurrency rejects) while musl
#   declares `extern FILE *const stderr;` (a `let`, which compiles fine). So a
#   green musl build does NOT prove the glibc build is green. The
#   `glibc-divergence` gate below statically flags the known-divergent cases.
#
# * NOT a replacement for Scripts/verify-all.sh (the gate of record).
#
# SETUP (one time). The SDK version must match the toolchain version.
#   1. Toolchain (does not change the swiftly global default):
#        swiftly install main-snapshot-2026-07-11
#   2. SDK — download, verify provenance against swift.org's PGP key, install:
#        URL=https://download.swift.org/development/static-sdk/swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a/swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a_static-linux-0.1.0.artifactbundle.tar.gz
#        curl -sSLO "$URL"
#        curl -sSLO "$URL.sig"
#        curl -sSL https://swift.org/keys/all-keys.asc | gpg --import -
#        gpg --verify swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a_static-linux-0.1.0.artifactbundle.tar.gz.sig
#        # expect: Good signature from "Swift Automatic Signing Key #4"
#        swiftly run swift sdk install ./swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a_static-linux-0.1.0.artifactbundle.tar.gz +main-snapshot-2026-07-11
#
#      sha256 of the bundle downloaded 2026-08-20:
#        15c31fee6c2382df94cf8fbace981ca9b500600d2e5b8ce5a3e17b7ce1feb282
#      That digest was computed here, from the same file whose `.sig` verified —
#      treat it as a CHANGE DETECTOR (did I get the same bytes again?), not as
#      provenance. The PGP signature is the provenance check; do not skip it.
#
# HARD RULES (same as check-server-snapshot.sh): never change the swiftly global
# default, never touch the repo's machine-local `.swift-version`, never use a
# snapshot toolchain for desktop work (SwiftData macros break). The toolchain is
# selected per-invocation via swiftly's `+toolchain` selector only.
#
# Overrides: ABBEY_LINUX_TOOLCHAIN, ABBEY_LINUX_SWIFT_SDK, ABBEY_LINUX_SDK_BUNDLE,
#            ABBEY_LINUX_BUILD_DIR, ABBEY_LINUX_LOG_DIR.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 70
# TOOLCHAINS=swift would drag toolchain resolution sideways; swiftly's +selector
# is the only selection mechanism we want active here.
unset TOOLCHAINS || true

# The toolchain is PINNED, not auto-picked. check-server-snapshot.sh picks the
# newest installed main-snapshot; doing that here would silently pair (say)
# main-snapshot-2026-08-11 with the 2026-07-11 SDK, and the version mismatch
# surfaces as a confusing build error rather than an install error.
TOOLCHAIN="${ABBEY_LINUX_TOOLCHAIN:-main-snapshot-2026-07-11}"
SWIFT_SDK="${ABBEY_LINUX_SWIFT_SDK:-x86_64-swift-linux-musl}"
SDK_BUNDLE="${ABBEY_LINUX_SDK_BUNDLE:-swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a_static-linux-0.1.0}"

command -v swiftly >/dev/null 2>&1 || {
    echo "SERVER_LINUX_FAIL: swiftly not found on PATH." >&2
    echo "  Install swiftly (https://www.swift.org/swiftly/), or run the Docker CI image instead." >&2
    exit 69
}

if ! swiftly list 2>/dev/null | grep -qF "$TOOLCHAIN"; then
    echo "SERVER_LINUX_FAIL: toolchain '$TOOLCHAIN' is not installed in swiftly." >&2
    echo "  Install it with: swiftly install $TOOLCHAIN   (does not change the global default)" >&2
    echo "  The Static Linux SDK must match the toolchain version — see this script's header." >&2
    exit 69
fi

SDK_LIST="$(swiftly run swift sdk list "+$TOOLCHAIN" 2>&1)"
if ! printf '%s\n' "$SDK_LIST" | grep -qF "$SDK_BUNDLE"; then
    echo "SERVER_LINUX_FAIL: Static Linux SDK '$SDK_BUNDLE' is not installed for $TOOLCHAIN." >&2
    echo "  swift sdk list said:" >&2
    printf '%s\n' "$SDK_LIST" | sed 's/^/    /' >&2
    echo "  Install it by following the SETUP block at the top of $0 (download," >&2
    echo "  gpg --verify against swift.org's key, then swift sdk install)." >&2
    exit 69
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${ABBEY_LINUX_LOG_DIR:-${TMPDIR:-/tmp}/AbbeyBot.server-linux-logs/$STAMP}"
SCRATCH="${ABBEY_LINUX_BUILD_DIR:-${TMPDIR:-/tmp}/AbbeyBot.server-linux.build}"
mkdir -p "$LOG_DIR"

echo "SERVER_LINUX toolchain:  $TOOLCHAIN"
echo "SERVER_LINUX swift-sdk:  $SWIFT_SDK  (bundle: $SDK_BUNDLE)"
echo "SERVER_LINUX libc:       musl  (CI is glibc/bookworm — see glibc-divergence gate)"
echo "SERVER_LINUX scratch:    $SCRATCH"
echo "SERVER_LINUX logs:       $LOG_DIR"
swiftly run swift --version "+$TOOLCHAIN" 2>&1 | sed 's/^/  /'

FAILED=0

# run_gate <name> -- <swift args...>
run_gate() {
    local name="$1"; shift
    while [[ "$1" != "--" ]]; do shift; done
    shift
    local log="$LOG_DIR/$name.log"
    echo "== GATE $name =="
    # CI passes only ABBEY_PACKAGE_ROLE into the container for build steps;
    # scrub DATABASE_URL so a shell-local value cannot change behaviour.
    env -u DATABASE_URL ABBEY_PACKAGE_ROLE=server \
        swiftly run swift "$@" \
        --swift-sdk "$SWIFT_SDK" \
        --scratch-path "$SCRATCH" \
        "+$TOOLCHAIN" \
        >"$log" 2>&1
    local rc=$?
    echo "GATE $name EXIT: $rc (log: $log)"
    if [[ $rc -ne 0 ]]; then
        FAILED=1
        grep -nE '(error|warning):' "$log" | head -40 | sed 's/^/  | /'
    fi
    return $rc
}

run_gate resolve -- package resolve || true
if [[ $FAILED -ne 0 ]]; then echo "SERVER_LINUX_FAIL: resolve failed"; exit 1; fi

run_gate build -- build --product AbbeyBot || true
if [[ $FAILED -ne 0 ]]; then echo "SERVER_LINUX_FAIL: build failed"; exit 1; fi

# ---------------------------------------------------------------------------
# GATE glibc-divergence — static lint for the things a musl build CANNOT see.
#
# 1. The C stdio stream globals. glibc: `extern FILE *stdin/stdout/stderr;`
#    → imported into Swift as `var` → Swift 6 strict concurrency rejects any
#    reference ("reference to var 'stderr' is not concurrency-safe because it
#    involves shared mutable state"). musl: `extern FILE *const ...` → `let` →
#    compiles clean. Use FileHandle.standardError / .standardOutput instead.
# 2. `canImport(Glibc)` branches. Under this SDK the module is `Musl`, so those
#    branches are NOT compiled here but ARE compiled in CI. A file that guards
#    on Glibc without a Musl companion has code this gate cannot vouch for.
#
# Comments are stripped (`//...` to end of line) before matching so the prose
# in this repo that *discusses* `stderr` does not trip the lint. Block comments
# are not stripped; keep libc symbol names out of /* */ blocks.
#
# SCOPE is deliberately the server graph only. Sources/AbbeyBotApp and
# Sources/AbbeyMediaMacOS are desktop-only targets that Linux never compiles
# (ABBEY_PACKAGE_ROLE=server omits them from the package graph entirely), and on
# Darwin `stderr` is a perfectly legal `let`. Linting them here would fail a
# Linux gate over code Linux never sees.
# ---------------------------------------------------------------------------
SERVER_GRAPH_PATHS=(
    Sources/AbbeyCore
    Sources/AbbeyServerKit
    Sources/AbbeyServer
    Sources/AbbeyCLI
    Sources/AbbeyEntry
    Tests/AbbeyCoreTests
    Tests/AbbeyCLITests
    Tests/AbbeyServerKitTests
    Tests/AbbeyServerTests
)

LINT_LOG="$LOG_DIR/glibc-divergence.log"
echo "== GATE glibc-divergence =="
: >"$LINT_LOG"
LINT_RC=0

while IFS= read -r file; do
    hits="$(sed 's://.*::' "$file" | grep -nE '(^|[^.[:alnum:]_"])(stdin|stdout|stderr)([^([:alnum:]_]|$)' || true)"
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits" | sed "s|^|$file:|" >>"$LINT_LOG"
        LINT_RC=1
    fi
done < <(find "${SERVER_GRAPH_PATHS[@]}" -name '*.swift' -type f)

if [[ $LINT_RC -ne 0 ]]; then
    echo "  glibc-divergence: reference(s) to the C stdio stream globals." >&2
    echo "  These compile under musl (const) and FAIL under glibc (mutable var)." >&2
    echo "  Replace with FileHandle.standardError / FileHandle.standardOutput." >&2
    sed 's/^/  | /' "$LINT_LOG" >&2
    FAILED=1
fi

# Advisory only (does not fail the gate): Glibc-guarded code not exercised here.
UNEXERCISED="$(grep -rln 'canImport(Glibc)' "${SERVER_GRAPH_PATHS[@]}" 2>/dev/null | while IFS= read -r f; do
    grep -q 'canImport(Musl)' "$f" || printf '%s\n' "$f"
done)"
if [[ -n "$UNEXERCISED" ]]; then
    echo "  NOTE: canImport(Glibc) without a canImport(Musl) companion — these branches"
    echo "        are NOT compiled by this musl SDK, so this run says nothing about them:"
    printf '%s\n' "$UNEXERCISED" | sed 's/^/          /'
fi
echo "GATE glibc-divergence EXIT: $LINT_RC (log: $LINT_LOG)"

echo
echo "NOTE: test targets were NOT compiled — the Static Linux SDK ships no Testing/XCTest."
echo "      Run 'bash Scripts/check-server-snapshot.sh' for the test-source coverage."

if [[ $FAILED -ne 0 ]]; then
    echo "SERVER_LINUX_FAIL: one or more gates failed (logs: $LOG_DIR)"
    exit 1
fi
echo "SERVER_LINUX_GREEN ($TOOLCHAIN / $SWIFT_SDK) — product graph only, musl not glibc"
