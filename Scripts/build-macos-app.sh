#!/usr/bin/env bash
# Assemble the SwiftPM AbbeyBot executable as a hardened-runtime macOS app bundle.
#
# Configuration:
#   ABBEY_APP_CONFIGURATION=debug|release   (default: debug)
#   ABBEY_CODESIGN_IDENTITY=-|<identity>    (default: ad-hoc "-")
#   ABBEY_CODESIGN_TIMESTAMP=1              (opt in to a signing timestamp)
#   ABBEY_NATIVE_PREFIX=/path/to/prefix     (optional Frameworks/lib embedding)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# SwiftData desktop builds require the Xcode SDK/toolchain, never swiftly.
unset TOOLCHAINS || true
unset ABBEY_PACKAGE_ROLE || true

SWIFT=(/usr/bin/xcrun --toolchain default swift)
CONFIGURATION="${ABBEY_APP_CONFIGURATION:-debug}"
BUILD_PATH="${ABBEY_APP_BUILD_PATH:-${TMPDIR:-/tmp}/AbbeyBot.app.build}"
APP_PATH="${ABBEY_APP_OUTPUT_PATH:-$BUILD_PATH/AbbeyBot.app}"
INFO_PLIST="$ROOT/Support/AbbeyBot/Info.plist"
ENTITLEMENTS="$ROOT/Support/AbbeyBot/AbbeyBot.entitlements"
IDENTITY="${ABBEY_CODESIGN_IDENTITY:--}"
NATIVE_PREFIX="${ABBEY_NATIVE_PREFIX:-}"

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    echo "error: ABBEY_APP_CONFIGURATION must be debug or release (got: $CONFIGURATION)" >&2
    exit 2
    ;;
esac
case "$APP_PATH" in
  /*.app) ;;
  *)
    echo "error: ABBEY_APP_OUTPUT_PATH must be an absolute path ending in .app: $APP_PATH" >&2
    exit 2
    ;;
esac
if [[ -z "$IDENTITY" ]]; then
  echo "error: ABBEY_CODESIGN_IDENTITY must not be empty (use '-' for ad-hoc signing)" >&2
  exit 2
fi

/usr/bin/plutil -lint "$INFO_PLIST" "$ENTITLEMENTS"

echo "Building AbbeyBot ($CONFIGURATION) with Xcode's default Swift toolchain…"
"${SWIFT[@]}" build \
  --configuration "$CONFIGURATION" \
  --build-path "$BUILD_PATH" \
  --product AbbeyBot
BIN_DIR="$("${SWIFT[@]}" build \
  --configuration "$CONFIGURATION" \
  --build-path "$BUILD_PATH" \
  --show-bin-path)"
BUILT_EXECUTABLE="$BIN_DIR/AbbeyBot"
if [[ ! -x "$BUILT_EXECUTABLE" ]]; then
  echo "error: built AbbeyBot executable not found at $BUILT_EXECUTABLE" >&2
  exit 1
fi

APP_PARENT="$(dirname "$APP_PATH")"
/bin/mkdir -p "$APP_PARENT"
STAGE_ROOT="$(mktemp -d "$APP_PARENT/.AbbeyBot.app.stage.XXXXXX")"
STAGE_APP="$STAGE_ROOT/AbbeyBot.app"
cleanup() {
  /bin/rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT

MACOS_DIR="$STAGE_APP/Contents/MacOS"
RESOURCES_DIR="$STAGE_APP/Contents/Resources"
FRAMEWORKS_DIR="$STAGE_APP/Contents/Frameworks"
/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
/bin/cp -p "$INFO_PLIST" "$STAGE_APP/Contents/Info.plist"
/bin/cp -p "$BUILT_EXECUTABLE" "$MACOS_DIR/AbbeyBot"
/bin/chmod 755 "$MACOS_DIR/AbbeyBot"

# Bundle.module looks for SwiftPM .bundle products below Bundle.main.resourceURL.
resource_count=0
shopt -s nullglob
resource_entries=("$BIN_DIR"/*.bundle "$BIN_DIR"/*.resources)
for resource in "${resource_entries[@]}"; do
  [[ -d "$resource" ]] || continue
  /usr/bin/ditto "$resource" "$RESOURCES_DIR/$(basename "$resource")"
  resource_count=$((resource_count + 1))
done
echo "Packaged $resource_count SwiftPM resource bundle(s)."

copy_native_directory() {
  local source_dir="$1"
  local entry destination
  [[ -d "$source_dir" ]] || return 0
  local native_entries=("$source_dir"/*.framework "$source_dir"/*.dylib)
  for entry in "${native_entries[@]}"; do
    destination="$FRAMEWORKS_DIR/$(basename "$entry")"
    if [[ -e "$destination" || -L "$destination" ]]; then
      echo "warning: skipping duplicate native artifact: $entry" >&2
      continue
    fi
    if [[ -d "$entry" ]]; then
      /usr/bin/ditto "$entry" "$destination"
    else
      /bin/cp -Pp "$entry" "$destination"
    fi
  done
}

# Native media dependencies are optional. Merely setting a valid prefix opts in;
# an unset, missing, or empty prefix never blocks the ordinary desktop bundle.
if [[ -n "$NATIVE_PREFIX" ]]; then
  if [[ -d "$NATIVE_PREFIX" ]]; then
    copy_native_directory "$NATIVE_PREFIX/Frameworks"
    copy_native_directory "$NATIVE_PREFIX/lib"
    copy_native_directory "$NATIVE_PREFIX/lib64"
  else
    echo "warning: ABBEY_NATIVE_PREFIX does not exist; continuing without native artifacts: $NATIVE_PREFIX" >&2
  fi
fi

APP_EXECUTABLE="$MACOS_DIR/AbbeyBot"

# Xcode's SwiftPM linker can retain an absolute PackageFrameworks rpath. It is useful
# in the build tree but the finished application must not depend on that cache path.
while IFS= read -r linked_rpath; do
  [[ -n "$linked_rpath" ]] || continue
  case "$linked_rpath" in
    /*) /usr/bin/install_name_tool -delete_rpath "$linked_rpath" "$APP_EXECUTABLE" ;;
  esac
done < <(/usr/bin/otool -l "$APP_EXECUTABLE" | /usr/bin/awk '
  $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
  in_rpath && $1 == "path" { print $2; in_rpath = 0 }
')
remaining_rpaths="$(/usr/bin/otool -l "$APP_EXECUTABLE" | /usr/bin/awk '
  $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
  in_rpath && $1 == "path" { print $2; in_rpath = 0 }
')"
if /usr/bin/grep -Fq "$BUILD_PATH/" <<<"$remaining_rpaths"; then
  echo "error: packaged executable still contains an absolute SwiftPM build rpath" >&2
  exit 1
fi

native_entries=("$FRAMEWORKS_DIR"/*)
if [[ "${#native_entries[@]}" -gt 0 ]]; then
  if ! /usr/bin/otool -l "$APP_EXECUTABLE" \
    | /usr/bin/grep -Fq 'path @executable_path/../Frameworks '; then
    /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_EXECUTABLE"
  fi
fi

native_dependency_name() {
  local dependency="$1"
  local relative
  [[ -n "$NATIVE_PREFIX" ]] || return 1
  case "$dependency" in
    "$NATIVE_PREFIX/Frameworks/"*) relative="${dependency#"$NATIVE_PREFIX/Frameworks/"}" ;;
    "$NATIVE_PREFIX/lib/"*) relative="${dependency#"$NATIVE_PREFIX/lib/"}" ;;
    "$NATIVE_PREFIX/lib64/"*) relative="${dependency#"$NATIVE_PREFIX/lib64/"}" ;;
    *) return 1 ;;
  esac
  if [[ "$relative" == *.framework/* ]]; then
    printf '@rpath/%s\n' "$relative"
  else
    printf '@rpath/%s\n' "$(basename "$relative")"
  fi
}

patch_native_dependencies() {
  local macho="$1"
  local dependency replacement
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    if replacement="$(native_dependency_name "$dependency")"; then
      /usr/bin/install_name_tool -change "$dependency" "$replacement" "$macho"
    fi
  done < <(/usr/bin/otool -L "$macho" \
    | /usr/bin/tail -n +2 \
    | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/ (compatibility version.*$//')
}

patch_native_dependencies "$APP_EXECUTABLE"
while IFS= read -r -d '' native_binary; do
  if /usr/bin/file "$native_binary" | /usr/bin/grep -Fq 'Mach-O'; then
    relative_path="${native_binary#"$FRAMEWORKS_DIR/"}"
    if /usr/bin/file "$native_binary" | /usr/bin/grep -Fq 'dynamically linked shared library'; then
      /usr/bin/install_name_tool -id "@rpath/$relative_path" "$native_binary"
    fi
    patch_native_dependencies "$native_binary"
  fi
done < <(/usr/bin/find "$FRAMEWORKS_DIR" -type f -print0)

# DAVE is especially security-sensitive. When native embedding is enabled, prove a
# supplied libdave install name resolves through the app's Frameworks rpath.
if [[ -n "$NATIVE_PREFIX" ]] && [[ "${#native_entries[@]}" -gt 0 ]]; then
  while IFS= read -r -d '' dave_library; do
    dave_relative_path="${dave_library#"$FRAMEWORKS_DIR/"}"
    dave_install_name="$(/usr/bin/otool -D "$dave_library" | /usr/bin/tail -n +2 | /usr/bin/head -n 1)"
    if [[ "$dave_install_name" != "@rpath/$dave_relative_path" ]]; then
      echo "error: libdave install name is not @rpath-relative: $dave_library" >&2
      exit 1
    fi
  done < <(/usr/bin/find "$FRAMEWORKS_DIR" -type f -name 'libdave*.dylib' -print0)
fi

verify_no_native_prefix_reference() {
  local macho="$1"
  local dependency_listing
  dependency_listing="$(/usr/bin/otool -L "$macho")"
  if /usr/bin/grep -F "$NATIVE_PREFIX/" <<<"$dependency_listing" >/dev/null; then
    echo "error: bundled code still references ABBEY_NATIVE_PREFIX: $macho" >&2
    exit 1
  fi
}

if [[ -n "$NATIVE_PREFIX" ]] && [[ "${#native_entries[@]}" -gt 0 ]]; then
  verify_no_native_prefix_reference "$APP_EXECUTABLE"
  while IFS= read -r -d '' native_binary; do
    if /usr/bin/file "$native_binary" | /usr/bin/grep -Fq 'Mach-O'; then
      verify_no_native_prefix_reference "$native_binary"
    fi
  done < <(/usr/bin/find "$FRAMEWORKS_DIR" -type f -print0)
fi

if [[ "${ABBEY_CODESIGN_TIMESTAMP:-0}" == "1" ]]; then
  SIGN_TIMESTAMP=(--timestamp)
else
  SIGN_TIMESTAMP=(--timestamp=none)
fi
SIGN_BASE=(--force --sign "$IDENTITY" --options runtime "${SIGN_TIMESTAMP[@]}")

# Sign nested code before its enclosing framework and application.
while IFS= read -r -d '' dylib; do
  /usr/bin/codesign "${SIGN_BASE[@]}" "$dylib"
done < <(/usr/bin/find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0)
while IFS= read -r framework; do
  [[ -n "$framework" ]] || continue
  /usr/bin/codesign "${SIGN_BASE[@]}" "$framework"
done < <(/usr/bin/find "$FRAMEWORKS_DIR" -type d -name '*.framework' -print | /usr/bin/sort -r)

/usr/bin/codesign "${SIGN_BASE[@]}" \
  --entitlements "$ENTITLEMENTS" \
  "$STAGE_APP"

/usr/bin/plutil -lint "$STAGE_APP/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

SIGNED_ENTITLEMENTS="$STAGE_ROOT/signed-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$STAGE_APP" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
/usr/bin/plutil -lint "$SIGNED_ENTITLEMENTS"
for entitlement in com.apple.security.device.audio-input com.apple.security.device.camera; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$SIGNED_ENTITLEMENTS")"
  if [[ "$value" != "true" ]]; then
    echo "error: signed bundle is missing required entitlement: $entitlement" >&2
    exit 1
  fi
done
for forbidden_entitlement in com.apple.security.app-sandbox com.apple.security.device.screen-capture; do
  if /usr/libexec/PlistBuddy -c "Print :$forbidden_entitlement" "$SIGNED_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "error: signed bundle contains forbidden entitlement: $forbidden_entitlement" >&2
    exit 1
  fi
done

test -x "$STAGE_APP/Contents/MacOS/AbbeyBot"
test -d "$STAGE_APP/Contents/Resources"
test -d "$STAGE_APP/Contents/Frameworks"

# Replace only the explicitly resolved .app build artifact; retain the SwiftPM cache.
/bin/rm -rf "$APP_PATH"
/bin/mv "$STAGE_APP" "$APP_PATH"

echo "APP_PATH=$APP_PATH"
echo "SIGNING_IDENTITY=$IDENTITY"
