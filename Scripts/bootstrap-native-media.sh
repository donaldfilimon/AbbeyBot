#!/usr/bin/env bash
set -euo pipefail
umask 077

LIBDAVE_VERSION="1.1.1"
LIBDAVE_COMMIT="52cd56dc550f447fb354b3a06c9e2d2e2a4309c6"
OPUS_VERSION="1.6.1"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
SODIUM_VERSION="1.0.22"
SODIUM_SHA256="adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349"

PREFIX="${ABBEY_NATIVE_PREFIX:-${TMPDIR:-/tmp}/AbbeyBot.native/v1}"
CACHE_DIR="${ABBEY_NATIVE_CACHE:-$PREFIX/cache}"
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--dry-run]" >&2
    exit 64
fi

case "$PREFIX" in
    /*) ;;
    *) echo "ABBEY_NATIVE_PREFIX must be an absolute path" >&2; exit 64 ;;
esac
if [[ "$PREFIX" == "/" ]]; then
    echo "refusing to use filesystem root as ABBEY_NATIVE_PREFIX" >&2
    exit 64
fi
case "$CACHE_DIR" in
    /*) ;;
    *) echo "ABBEY_NATIVE_CACHE must be an absolute path" >&2; exit 64 ;;
esac
if [[ "$CACHE_DIR" == "/" ]]; then
    echo "refusing to use filesystem root as ABBEY_NATIVE_CACHE" >&2
    exit 64
fi

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS:$ARCH" in
    Darwin:arm64)
        DAVE_ARCHIVE="libdave-macOS-ARM64-boringssl.zip"
        DAVE_SHA256="ff8ae20332b4553cb61989cbcecd8dc4224edfc0ab9afdf7e23c1a9aa5ed748a"
        RUNTIME_PATH_NAME="DYLD_LIBRARY_PATH"
        ;;
    Darwin:x86_64)
        DAVE_ARCHIVE="libdave-macOS-X64-boringssl.zip"
        DAVE_SHA256="8588ba9e664f659b3b143ddccd2edccf4432de8150698e3c1ad401a9149ea851"
        RUNTIME_PATH_NAME="DYLD_LIBRARY_PATH"
        ;;
    Linux:aarch64|Linux:arm64)
        DAVE_ARCHIVE="libdave-Linux-ARM64-boringssl.zip"
        DAVE_SHA256="2848ca62da5c8303626cfa410827f37735455f614256311fc320b35c7c6a1975"
        RUNTIME_PATH_NAME="LD_LIBRARY_PATH"
        ;;
    Linux:x86_64|Linux:amd64)
        DAVE_ARCHIVE="libdave-Linux-X64-boringssl.zip"
        DAVE_SHA256="2470a131dbf39a820d893ba3d6f01373fc597868caffd6a30a8746e441ed5ede"
        RUNTIME_PATH_NAME="LD_LIBRARY_PATH"
        ;;
    *)
        echo "unsupported native media platform: $OS/$ARCH" >&2
        exit 69
        ;;
esac

DAVE_URL="https://github.com/discord/libdave/releases/download/v${LIBDAVE_VERSION}/cpp/${DAVE_ARCHIVE}"
OPUS_ARCHIVE="opus-${OPUS_VERSION}.tar.gz"
OPUS_URL="https://downloads.xiph.org/releases/opus/${OPUS_ARCHIVE}"
SODIUM_ARCHIVE="libsodium-${SODIUM_VERSION}.tar.gz"
SODIUM_URL="https://download.libsodium.org/libsodium/releases/${SODIUM_ARCHIVE}"

if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'prefix=%s\ncache=%s\nplatform=%s/%s\n' "$PREFIX" "$CACHE_DIR" "$OS" "$ARCH"
    printf 'libdave=%s commit=%s archive=%s sha256=%s\n' \
        "$LIBDAVE_VERSION" "$LIBDAVE_COMMIT" "$DAVE_ARCHIVE" "$DAVE_SHA256"
    printf 'opus=%s archive=%s sha256=%s\n' "$OPUS_VERSION" "$OPUS_ARCHIVE" "$OPUS_SHA256"
    printf 'libsodium=%s archive=%s sha256=%s\n' \
        "$SODIUM_VERSION" "$SODIUM_ARCHIVE" "$SODIUM_SHA256"
    exit 0
fi

for command in curl make tar unzip; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "required command not found: $command" >&2
        exit 69
    }
done
if command -v shasum >/dev/null 2>&1; then
    checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
    checksum() { sha256sum "$1" | awk '{print $1}'; }
else
    echo "required SHA-256 tool not found (shasum or sha256sum)" >&2
    exit 69
fi

BUILD_ROOT="$PREFIX/build"
mkdir -p "$CACHE_DIR" "$BUILD_ROOT" "$PREFIX/include" "$PREFIX/lib/pkgconfig" "$PREFIX/share/licenses"

# Keep build-system caches and temporary files within the selected prefix.
mkdir -p "$PREFIX/tmp" "$PREFIX/xdg-cache"
export TMPDIR="$PREFIX/tmp"
export XDG_CACHE_HOME="$PREFIX/xdg-cache"

download_verified() {
    local url="$1"
    local expected="$2"
    local destination="$3"
    if [[ -f "$destination" ]] && [[ "$(checksum "$destination")" == "$expected" ]]; then
        printf 'verified cached %s\n' "$(basename "$destination")"
        return
    fi
    rm -f "$destination" "$destination.part"
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 \
        --output "$destination.part" "$url"
    local actual
    actual="$(checksum "$destination.part")"
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$destination.part"
        echo "checksum mismatch for $(basename "$destination"): expected $expected, got $actual" >&2
        exit 65
    fi
    mv "$destination.part" "$destination"
    printf 'downloaded and verified %s\n' "$(basename "$destination")"
}

DAVE_PATH="$CACHE_DIR/$DAVE_ARCHIVE"
OPUS_PATH="$CACHE_DIR/$OPUS_ARCHIVE"
SODIUM_PATH="$CACHE_DIR/$SODIUM_ARCHIVE"
download_verified "$DAVE_URL" "$DAVE_SHA256" "$DAVE_PATH"
download_verified "$OPUS_URL" "$OPUS_SHA256" "$OPUS_PATH"
download_verified "$SODIUM_URL" "$SODIUM_SHA256" "$SODIUM_PATH"

WORK_DIR="$(mktemp -d "$BUILD_ROOT/run.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

mkdir -p "$WORK_DIR/libdave"
unzip -q "$DAVE_PATH" -d "$WORK_DIR/libdave"
cp -R "$WORK_DIR/libdave/include/." "$PREFIX/include/"
cp -R "$WORK_DIR/libdave/lib/." "$PREFIX/lib/"
mkdir -p "$PREFIX/share/licenses/libdave-${LIBDAVE_VERSION}"
cp -R "$WORK_DIR/libdave/licenses/." "$PREFIX/share/licenses/libdave-${LIBDAVE_VERSION}/"

# SwiftPM's macOS test helper sanitizes DYLD_LIBRARY_PATH. Give the verified copy an
# absolute install name for this explicit prefix, then restore its ad-hoc signature.
if [[ "$OS" == "Darwin" ]]; then
    command -v install_name_tool >/dev/null 2>&1 || {
        echo "required command not found: install_name_tool" >&2
        exit 69
    }
    command -v codesign >/dev/null 2>&1 || {
        echo "required command not found: codesign" >&2
        exit 69
    }
    install_name_tool -id "$PREFIX/lib/libdave.dylib" "$PREFIX/lib/libdave.dylib"
    codesign --force --sign - "$PREFIX/lib/libdave.dylib"
fi

SOURCE_BUILD_REQUIRED=1
if [[ -f "$PREFIX/.abbey-native-versions" ]] \
    && grep -Fqx "opus=$OPUS_VERSION" "$PREFIX/.abbey-native-versions" \
    && grep -Fqx "libsodium=$SODIUM_VERSION" "$PREFIX/.abbey-native-versions" \
    && [[ -f "$PREFIX/lib/libopus.a" ]] \
    && [[ -f "$PREFIX/lib/libsodium.a" ]] \
    && [[ -f "$PREFIX/include/opus/opus.h" ]] \
    && [[ -f "$PREFIX/include/sodium.h" ]] \
    && [[ -f "$PREFIX/share/licenses/opus-${OPUS_VERSION}/COPYING" ]] \
    && [[ -f "$PREFIX/share/licenses/libsodium-${SODIUM_VERSION}/LICENSE" ]]; then
    SOURCE_BUILD_REQUIRED=0
fi

if [[ "$SOURCE_BUILD_REQUIRED" -eq 1 ]]; then
    tar -xzf "$OPUS_PATH" -C "$WORK_DIR"
    tar -xzf "$SODIUM_PATH" -C "$WORK_DIR"

    if [[ "$OS" == "Darwin" ]]; then
        JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
    else
        JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    fi
    case "$JOBS" in ''|*[!0-9]*) JOBS=1 ;; esac

    (
        cd "$WORK_DIR/opus-${OPUS_VERSION}"
        ./configure --prefix="$PREFIX" --disable-dependency-tracking --disable-doc \
            --disable-extra-programs --disable-shared --enable-static
        make -j"$JOBS"
        make install
    )
    (
        cd "$WORK_DIR/libsodium-${SODIUM_VERSION}"
        ./configure --prefix="$PREFIX" --disable-dependency-tracking --disable-shared --enable-static
        make -j"$JOBS"
        make install
    )

    mkdir -p "$PREFIX/share/licenses/opus-${OPUS_VERSION}" "$PREFIX/share/licenses/libsodium-${SODIUM_VERSION}"
    cp "$WORK_DIR/opus-${OPUS_VERSION}/COPYING" "$PREFIX/share/licenses/opus-${OPUS_VERSION}/COPYING"
    cp "$WORK_DIR/libsodium-${SODIUM_VERSION}/LICENSE" "$PREFIX/share/licenses/libsodium-${SODIUM_VERSION}/LICENSE"
else
    printf 'verified installed Opus %s and libsodium %s\n' "$OPUS_VERSION" "$SODIUM_VERSION"
fi

cat > "$PREFIX/lib/pkgconfig/libdave.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libdave
Description: Discord Audio and Video End-to-End Encryption C API
Version: $LIBDAVE_VERSION
Libs: -L\${libdir} -ldave
Cflags: -I\${includedir}
EOF

shell_escape() { printf '%q' "$1"; }
PREFIX_ESCAPED="$(shell_escape "$PREFIX")"
cat > "$PREFIX/abbey-native.env" <<EOF
# Generated by AbbeyBot Scripts/bootstrap-native-media.sh
export ABBEY_NATIVE_MEDIA=1
export ABBEY_NATIVE_PREFIX=$PREFIX_ESCAPED
export PKG_CONFIG_PATH=$PREFIX_ESCAPED/lib/pkgconfig:\${PKG_CONFIG_PATH:-}
export LIBRARY_PATH=$PREFIX_ESCAPED/lib:\${LIBRARY_PATH:-}
EOF
if [[ "$RUNTIME_PATH_NAME" == "DYLD_LIBRARY_PATH" ]]; then
    printf 'export DYLD_LIBRARY_PATH=%s/lib:${DYLD_LIBRARY_PATH:-}\n' "$PREFIX_ESCAPED" >> "$PREFIX/abbey-native.env"
else
    printf 'export LD_LIBRARY_PATH=%s/lib:${LD_LIBRARY_PATH:-}\n' "$PREFIX_ESCAPED" >> "$PREFIX/abbey-native.env"
fi

cat > "$PREFIX/.abbey-native-versions" <<EOF
libdave=$LIBDAVE_VERSION
libdave_commit=$LIBDAVE_COMMIT
opus=$OPUS_VERSION
libsodium=$SODIUM_VERSION
EOF

printf '\nNative media dependencies installed at %s\n' "$PREFIX"
printf 'Load the opt-in build environment with:\n  source %q\n' "$PREFIX/abbey-native.env"
