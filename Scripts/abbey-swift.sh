#!/usr/bin/env bash
# Resolve which `swift` to use for Abbey launchers.
#
# Default: Xcode via xcrun (required for desktop SwiftData).
# Opt-in swiftly for server/CLI (server-only package graph):
#   ABBEY_SWIFT=swiftly bash Scripts/run-server.sh
#
# Usage (sourced by run*.sh):
#   source Scripts/abbey-swift.sh
#   abbey_swift_run <build-path-suffix> <role> [-- args...]
#   role: desktop | server | cli
set -euo pipefail

abbey_resolve_swift() {
  local mode="${ABBEY_SWIFT:-xcode}"
  case "$mode" in
    xcode|Xcode|"")
      unset TOOLCHAINS || true
      ABBEY_SWIFT_BIN=(/usr/bin/xcrun --toolchain default swift)
      ABBEY_SWIFT_LABEL="xcode"
      ;;
    swiftly|SWIFTLY|path)
      if [[ -x "${HOME}/.swiftly/bin/swift" ]]; then
        export PATH="${HOME}/.swiftly/bin:${PATH}"
      fi
      unset TOOLCHAINS || true
      ABBEY_SWIFT_BIN=(swift)
      ABBEY_SWIFT_LABEL="swiftly"
      ;;
    *)
      echo "ABBEY_SWIFT must be 'xcode' or 'swiftly' (got: $mode)" >&2
      return 1
      ;;
  esac
}

# Desktop SwiftData macros (@Query, \.modelContext, .modelContainer) break under
# swiftly DEVELOPMENT-SNAPSHOT mixed with the macOS 27 SDK. Refuse early.
abbey_assert_desktop_toolchain() {
  local ver
  if ! ver="$("${ABBEY_SWIFT_BIN[@]}" --version 2>&1 | head -5)"; then
    ver=""
  fi
  if [[ -z "$ver" ]] \
    || [[ "$ABBEY_SWIFT_LABEL" == "swiftly" ]] \
    || [[ "$ver" == *DEVELOPMENT-SNAPSHOT* ]] \
    || [[ "$ver" == *6.5-dev* ]]; then
    echo "error: desktop must use Xcode Swift 6.4, not swiftly / DEVELOPMENT-SNAPSHOT." >&2
    echo "  PATH swift resolves to: $(command -v swift 2>/dev/null || echo '?')" >&2
    echo "  Got:" >&2
    if [[ -z "$ver" ]]; then
      echo "    (empty — swift --version failed or produced no output)" >&2
    else
      echo "$ver" | sed 's/^/    /' >&2
    fi
    echo "Fix:" >&2
    echo "  unset TOOLCHAINS" >&2
    echo "  bash Scripts/run.sh" >&2
    echo "  # or: /usr/bin/xcrun --toolchain default swift run --build-path \"\${TMPDIR}/AbbeyBot.desktop.build\"" >&2
    return 1
  fi
}

abbey_swift_run() {
  local build_suffix="$1"
  local role="$2"
  shift 2

  abbey_resolve_swift

  if [[ "$role" == "desktop" ]]; then
    abbey_assert_desktop_toolchain || return 1
  fi

  local build_path="${TMPDIR:-/tmp}/AbbeyBot.${build_suffix}.build"
  if [[ "$ABBEY_SWIFT_LABEL" == "swiftly" ]]; then
    build_path="${TMPDIR:-/tmp}/AbbeyBot.swiftly.${build_suffix}.build"
    echo "Using swiftly PATH swift ($(command -v swift))" >&2
  fi

  case "$role" in
    desktop)
      unset ABBEY_PACKAGE_ROLE || true
      # Sole executable product — bare `swift run` also works without naming it.
      exec "${ABBEY_SWIFT_BIN[@]}" run --build-path "$build_path" AbbeyBot "$@"
      ;;
    server)
      export ABBEY_PACKAGE_ROLE=server
      # Name the product so `serve` is an app arg, not an SPM product name.
      exec "${ABBEY_SWIFT_BIN[@]}" run --build-path "$build_path" AbbeyBot serve "$@"
      ;;
    cli)
      export ABBEY_PACKAGE_ROLE=server
      exec "${ABBEY_SWIFT_BIN[@]}" run --build-path "$build_path" AbbeyBot cli "$@"
      ;;
    *)
      echo "abbey_swift_run: role must be desktop|server|cli (got: $role)" >&2
      return 1
      ;;
  esac
}
