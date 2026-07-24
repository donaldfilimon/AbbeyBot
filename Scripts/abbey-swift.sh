#!/usr/bin/env bash
# Resolve which `swift` to use for Abbey launchers.
#
# Default: Xcode via xcrun (required for desktop SwiftData).
# Opt-in swiftly for AbbeyServer / abbey only:
#   ABBEY_SWIFT=swiftly bash Scripts/run-server.sh
#
# Usage (sourced by run*.sh):
#   source Scripts/abbey-swift.sh
#   abbey_swift_run <build-path-suffix> <product> [-- args...]
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

abbey_swift_run() {
  local build_suffix="$1"
  local product="$2"
  shift 2

  abbey_resolve_swift

  if [[ "$product" == "AbbeyBot" && "$ABBEY_SWIFT_LABEL" == "swiftly" ]]; then
    echo "error: desktop AbbeyBot cannot build under swiftly (SwiftData @Query / \\.modelContext break)." >&2
    echo "Use: bash Scripts/run.sh   # Xcode toolchain" >&2
    return 1
  fi

  local build_path="${TMPDIR:-/tmp}/AbbeyBot.${build_suffix}.build"
  if [[ "$ABBEY_SWIFT_LABEL" == "swiftly" ]]; then
    build_path="${TMPDIR:-/tmp}/AbbeyBot.swiftly.${build_suffix}.build"
    echo "Using swiftly PATH swift ($(command -v swift))" >&2
  fi

  exec "${ABBEY_SWIFT_BIN[@]}" run --build-path "$build_path" "$product" "$@"
}
