#!/usr/bin/env bash
# Assert that ordinary builds stay native-free and explicit opt-in exposes the
# native targets. This checks manifest selection only; native linking belongs
# to run-native-media-smoke.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true

command -v python3 >/dev/null 2>&1 || {
    echo "PACKAGE_GRAPHS_FAIL: required command not found: python3" >&2
    exit 69
}
if [[ "$(uname -s)" == "Darwin" ]]; then
    command -v /usr/bin/xcrun >/dev/null 2>&1 || {
        echo "PACKAGE_GRAPHS_FAIL: xcrun is required on Darwin" >&2
        exit 69
    }
    /usr/bin/xcrun --toolchain default --find swift >/dev/null 2>&1 || {
        echo "PACKAGE_GRAPHS_FAIL: Swift is unavailable in the default Xcode toolchain" >&2
        exit 69
    }
    SWIFT=(/usr/bin/xcrun --toolchain default swift)
else
    SWIFT_BIN="${ABBEY_SWIFT:-swift}"
    command -v "$SWIFT_BIN" >/dev/null 2>&1 || {
        echo "PACKAGE_GRAPHS_FAIL: Swift driver not found: $SWIFT_BIN" >&2
        exit 69
    }
    SWIFT=("$SWIFT_BIN")
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/abbey-package-graphs.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

dump_graph() {
    local destination="$1"
    shift
    env -u ABBEY_NATIVE_MEDIA -u ABBEY_NATIVE_PREFIX -u ABBEY_NATIVE_CACHE \
        "$@" "${SWIFT[@]}" package dump-package >"$destination"
}

dump_graph "$WORK_DIR/desktop-default.json" env -u ABBEY_PACKAGE_ROLE
dump_graph "$WORK_DIR/server-default.json" env ABBEY_PACKAGE_ROLE=server
env -u ABBEY_PACKAGE_ROLE -u ABBEY_NATIVE_PREFIX -u ABBEY_NATIVE_CACHE \
    ABBEY_NATIVE_MEDIA=1 \
    "${SWIFT[@]}" package dump-package >"$WORK_DIR/desktop-native.json"
env -u ABBEY_NATIVE_PREFIX -u ABBEY_NATIVE_CACHE \
    ABBEY_PACKAGE_ROLE=server ABBEY_NATIVE_MEDIA=1 \
    "${SWIFT[@]}" package dump-package >"$WORK_DIR/server-native.json"

python3 - "$WORK_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
native_names = {"CLibDave", "COpus", "CSodium", "AbbeyMediaNative", "AbbeyMediaNativeTests"}
desktop_only_names = {"AbbeyBotApp", "AbbeyBotAppTests", "AbbeyMediaMacOS", "AbbeyMediaMacOSTests"}
shared_quasar_names = {"AbbeyQuasarKit", "AbbeyQuasarKitTests"}

def names(path):
    package = json.loads(path.read_text())
    targets = {target["name"] for target in package.get("targets", [])}
    products = {product["name"] for product in package.get("products", [])}
    return targets | products

for filename in ("desktop-default.json", "server-default.json"):
    leaked = names(root / filename) & native_names
    if leaked:
        raise SystemExit(f"{filename} unexpectedly contains native graph entries: {sorted(leaked)}")

for filename in ("desktop-native.json", "server-native.json"):
    missing = native_names - names(root / filename)
    if missing:
        raise SystemExit(f"{filename} is missing native opt-in entries: {sorted(missing)}")

for filename in ("desktop-default.json", "desktop-native.json"):
    missing = desktop_only_names - names(root / filename)
    if missing:
        raise SystemExit(f"{filename} is missing desktop-only entries: {sorted(missing)}")

for filename in ("server-default.json", "server-native.json"):
    leaked = names(root / filename) & desktop_only_names
    if leaked:
        raise SystemExit(f"{filename} unexpectedly contains desktop-only entries: {sorted(leaked)}")

for filename in ("desktop-default.json", "desktop-native.json", "server-default.json", "server-native.json"):
    missing = shared_quasar_names - names(root / filename)
    if missing:
        raise SystemExit(f"{filename} is missing shared Quasar entries: {sorted(missing)}")
PY

echo "PACKAGE_GRAPHS_GREEN"
