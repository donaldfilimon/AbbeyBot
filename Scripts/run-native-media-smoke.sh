#!/usr/bin/env bash
# Explicit native-media release gate. Default execution bootstraps into a fresh
# temporary prefix/cache, verifies the install, proves rerun safety, and runs the
# complete native suite in debug and release. It is intentionally separate from
# verify-all.sh because native dependencies are opt-in.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true

if [[ "$(uname -s)" == "Darwin" ]]; then
    unset ABBEY_PACKAGE_ROLE || true
    command -v /usr/bin/xcrun >/dev/null 2>&1 || {
        echo "NATIVE_MEDIA_SMOKE_FAIL: xcrun is required on Darwin" >&2
        exit 69
    }
    /usr/bin/xcrun --toolchain default --find swift >/dev/null 2>&1 || {
        echo "NATIVE_MEDIA_SMOKE_FAIL: Swift is unavailable in the default Xcode toolchain" >&2
        exit 69
    }
    SWIFT=(/usr/bin/xcrun --toolchain default swift)
else
    export ABBEY_PACKAGE_ROLE=server
    SWIFT_BIN="${ABBEY_SWIFT:-swift}"
    command -v "$SWIFT_BIN" >/dev/null 2>&1 || {
        echo "NATIVE_MEDIA_SMOKE_FAIL: Swift driver not found: $SWIFT_BIN" >&2
        exit 69
    }
    SWIFT=("$SWIFT_BIN")
fi

for command in pkg-config python3; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "NATIVE_MEDIA_SMOKE_FAIL: required command not found: $command" >&2
        exit 69
    }
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/abbey-native-smoke.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
export ABBEY_NATIVE_PREFIX="$WORK_DIR/prefix"
export ABBEY_NATIVE_CACHE="$WORK_DIR/cache"

echo "======== native 1/9 fresh pinned bootstrap ========"
bash Scripts/bootstrap-native-media.sh

echo "======== native 2/9 installed manifest ========"
python3 - "$ABBEY_NATIVE_PREFIX" <<'PY'
import pathlib
import sys

prefix = pathlib.Path(sys.argv[1])
expected_versions = {
    "libdave": "1.1.1",
    "libdave_commit": "52cd56dc550f447fb354b3a06c9e2d2e2a4309c6",
    "opus": "1.6.1",
    "libsodium": "1.0.22",
}
actual = {}
for line in (prefix / ".abbey-native-versions").read_text().splitlines():
    key, value = line.split("=", 1)
    actual[key] = value
if actual != expected_versions:
    raise SystemExit(f"unexpected native versions metadata: {actual!r}")

required_files = [
    "abbey-native.env",
    "include/dave/dave.h",
    "include/opus/opus.h",
    "include/sodium.h",
    "lib/libopus.a",
    "lib/libsodium.a",
    "lib/pkgconfig/libdave.pc",
    "lib/pkgconfig/opus.pc",
    "lib/pkgconfig/libsodium.pc",
    "share/licenses/libdave-1.1.1/libdave",
    "share/licenses/libdave-1.1.1/nlohmann-json",
    "share/licenses/libdave-1.1.1/boringssl",
    "share/licenses/libdave-1.1.1/mlspp",
    "share/licenses/opus-1.6.1/COPYING",
    "share/licenses/libsodium-1.0.22/LICENSE",
]
required_files.append("lib/libdave.dylib" if sys.platform == "darwin" else "lib/libdave.so")
missing = [entry for entry in required_files if not (prefix / entry).is_file()]
if missing:
    raise SystemExit(f"native install is missing: {missing}")
PY

echo "======== native 3/9 rerun-safe verified bootstrap ========"
bash Scripts/bootstrap-native-media.sh

echo "======== native 4/9 installed versions ========"
# shellcheck disable=SC1090
source "$ABBEY_NATIVE_PREFIX/abbey-native.env"
# The fresh prefix is the sole pkg-config authority for every assertion and
# SwiftPM invocation below. A matching host installation must not mask a
# missing or malformed bootstrapped .pc file.
export PKG_CONFIG_PATH="$ABBEY_NATIVE_PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$ABBEY_NATIVE_PREFIX/lib/pkgconfig"
test "$(pkg-config --modversion libdave)" = "1.1.1"
test "$(pkg-config --modversion opus)" = "1.6.1"
test "$(pkg-config --modversion libsodium)" = "1.0.22"

echo "======== native 5/9 opt-in package graph ========"
"${SWIFT[@]}" package dump-package >"$WORK_DIR/native-package.json"
python3 - "$WORK_DIR/native-package.json" <<'PY'
import json
import pathlib
import sys
package = json.loads(pathlib.Path(sys.argv[1]).read_text())
names = {item["name"] for key in ("targets", "products") for item in package.get(key, [])}
required = {"CLibDave", "COpus", "CSodium", "AbbeyMediaNative", "AbbeyMediaNativeTests"}
missing = required - names
if missing:
    raise SystemExit(f"native graph missing entries: {sorted(missing)}")
PY

echo "======== native 6/9 debug suite ========"
"${SWIFT[@]}" test \
    --build-path "$WORK_DIR/debug-build" \
    --filter AbbeyMediaNativeTests

echo "======== native 7/9 release suite ========"
"${SWIFT[@]}" test -c release \
    --build-path "$WORK_DIR/release-build" \
    --filter AbbeyMediaNativeTests

echo "======== native 8/9 runtime output secrecy ========"
read -r SECRET_SENTINEL SECRET_GROUP_ID SECRET_USER_ID <<<"$(python3 <<'PY'
import secrets

sentinel = "abbey-native-secret-" + secrets.token_hex(24)
value = 14_695_981_039_346_656_037
for byte in sentinel.encode():
    value ^= byte
    value = (value * 1_099_511_628_211) & ((1 << 64) - 1)
group_id = value or 1
user_id = (value ^ 0x9e37_79b9_7f4a_7c15) or 2
print(sentinel, group_id, user_id)
PY
)"
for configuration in debug release; do
    output="$WORK_DIR/secrecy-$configuration.log"
    build="$WORK_DIR/$configuration-build"
    args=(test --build-path "$build" --filter runtimeNativeOutputSecrecyProbe)
    if [[ "$configuration" == "release" ]]; then
        args=(test -c release --build-path "$build" --filter runtimeNativeOutputSecrecyProbe)
    fi
    ABBEY_NATIVE_SECRET_SENTINEL="$SECRET_SENTINEL" \
    ABBEY_NATIVE_GROUP_ID_SENTINEL="$SECRET_GROUP_ID" \
    ABBEY_NATIVE_USER_ID_SENTINEL="$SECRET_USER_ID" \
        "${SWIFT[@]}" "${args[@]}" >"$output" 2>&1 || {
        echo "NATIVE_MEDIA_SMOKE_FAIL: runtime secrecy probe failed ($configuration)" >&2
        exit 1
    }
    if ! grep -Eq 'Test run with 1 test( |$)' "$output"; then
        echo "NATIVE_MEDIA_SMOKE_FAIL: runtime secrecy probe did not execute exactly once ($configuration)" >&2
        exit 1
    fi
    for secret_value in "$SECRET_SENTINEL" "$SECRET_GROUP_ID" "$SECRET_USER_ID"; do
        if grep -Fq -- "$secret_value" "$output"; then
            echo "NATIVE_MEDIA_SMOKE_FAIL: native runtime exposed sentinel material ($configuration)" >&2
            exit 1
        fi
    done
done
unset SECRET_SENTINEL SECRET_GROUP_ID SECRET_USER_ID

echo "======== native 9/9 static security ========"
bash Scripts/check-static-security.sh
echo "NATIVE_MEDIA_SMOKE_GREEN"
