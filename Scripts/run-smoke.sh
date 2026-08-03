#!/usr/bin/env bash
# Desktop smoke for AbbeyBot (macOS 27 / .macOS(.v27)).
# Always uses Xcode toolchain via xcrun — never PATH/swiftly DEVELOPMENT-SNAPSHOT.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
# Full package graph (SwiftUI/SwiftData) — never build desktop under server-only role.
unset ABBEY_PACKAGE_ROLE || true
# Native media is opt-in and has a separate gate.
unset ABBEY_NATIVE_MEDIA ABBEY_NATIVE_PREFIX ABBEY_NATIVE_CACHE || true
# Build off Desktop to avoid iCloud/Finder xattrs breaking ad-hoc codesign.
BUILD_PATH="${TMPDIR:-/tmp}/AbbeyBot.build"
SWIFT=(/usr/bin/xcrun --toolchain default swift)

echo "======== 1/5 debug build (macOS 27) ========"
"${SWIFT[@]}" build --build-path "$BUILD_PATH"

echo "======== 2/5 release build ========"
"${SWIFT[@]}" build -c release --build-path "$BUILD_PATH"

echo "======== 3/5 all Swift test targets ========"
# The desktop graph contains all five test bundles. Running without a filter prevents the
# release gate from silently omitting app, CLI, server-kit, or HTTP route tests.
"${SWIFT[@]}" test --build-path "$BUILD_PATH"

echo "======== 4/5 signed macOS application bundle ========"
APP_BUILD_PATH="$BUILD_PATH"
ABBEY_APP_BUILD_PATH="$APP_BUILD_PATH" bash "$ROOT/Scripts/build-macos-app.sh"
APP_PATH="$APP_BUILD_PATH/AbbeyBot.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/AbbeyBot"
# LaunchServices reports canonical /private paths even when TMPDIR is reached through
# /tmp or /var aliases. Resolve once so PID matching and termination remain exact.
APP_EXECUTABLE="$(cd "$(dirname "$APP_EXECUTABLE")" && pwd -P)/$(basename "$APP_EXECUTABLE")"

test -d "$APP_PATH/Contents/Resources"
test -d "$APP_PATH/Contents/Frameworks"
test -x "$APP_EXECUTABLE"
/usr/bin/plutil -lint "$INFO_PLIST"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" = "com.donaldfilimon.AbbeyBot"
test "$(/usr/bin/plutil -extract CFBundlePackageType raw "$INFO_PLIST")" = "APPL"
test "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")" = "27.0"

for privacy_key in \
  NSMicrophoneUsageDescription \
  NSCameraUsageDescription \
  NSScreenCaptureUsageDescription \
  NSAudioCaptureUsageDescription; do
  privacy_copy="$(/usr/bin/plutil -extract "$privacy_key" raw "$INFO_PLIST")"
  if [[ -z "$privacy_copy" ]]; then
    echo "error: empty privacy usage description: $privacy_key" >&2
    exit 1
  fi
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ENTITLEMENTS_DUMP="$(mktemp "${TMPDIR:-/tmp}/abbey-entitlements.XXXXXX")"
/usr/bin/codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_DUMP" 2>/dev/null
/usr/bin/plutil -lint "$ENTITLEMENTS_DUMP" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS_DUMP")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.camera' "$ENTITLEMENTS_DUMP")" = "true"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS_DUMP" >/dev/null 2>&1; then
  echo "error: App Sandbox must remain disabled until the ~/.abbey migration is resolved" >&2
  rm -f "$ENTITLEMENTS_DUMP"
  exit 1
fi
rm -f "$ENTITLEMENTS_DUMP"

echo "======== 5/5 LaunchServices media-disabled app launch ========"
# Isolate UserDefaults from host Settings. ABBEY_MEDIA_DISABLED prevents any capture
# session from starting during this metadata/runtime smoke, so no TCC prompt is expected.
SMOKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/abbey-smoke-home.XXXXXX")"
mkdir -p "$SMOKE_HOME/Library/Preferences"
HOME="$SMOKE_HOME" /usr/bin/open -n \
  --env HOME="$SMOKE_HOME" \
  --env ABBEY_MEDIA_DISABLED=1 \
  --env ABBEY_DRY_RUN=1 \
  --env ABBEY_INFERENCE_MODE=deterministicFloor \
  "$APP_PATH"

APP_PID=""
for _ in {1..20}; do
  while read -r candidate_pid candidate_command; do
    if [[ "$candidate_command" == "$APP_EXECUTABLE" || "$candidate_command" == "$APP_EXECUTABLE "* ]]; then
      APP_PID="$candidate_pid"
      break
    fi
  done < <(/bin/ps -axo pid=,command=)
  [[ -n "$APP_PID" ]] && break
  sleep 0.25
done

if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
  echo "LAUNCH_OK pid=$APP_PID media_disabled=1"
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  rm -rf "$SMOKE_HOME"
else
  echo "LAUNCH_FAILED"
  rm -rf "$SMOKE_HOME"
  exit 1
fi

echo
echo "======== ALL GATES GREEN ========"
