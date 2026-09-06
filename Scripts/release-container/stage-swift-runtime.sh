#!/usr/bin/env bash
# Stage the Swift runtime the built executable actually loads.
#
# The runtime directory is discovered, never assumed: toolchain images have moved
# it before (`/usr/lib/swift/linux` disappeared under swiftlang/swift nightly
# 6.4.x and broke a hardcoded `COPY --from=build`). `ldd` reports the path the
# linker resolved for this binary, which is the only path that is definitionally
# correct. `swiftc -print-target-info` is the documented fallback, and a short
# candidate list covers the case where neither tool is usable.
#
# On failure this lists what the toolchain actually ships, so one build reports
# the real layout instead of an opaque "not found" from the COPY.
set -euo pipefail
if (( $# != 2 )); then
  echo "usage: $0 EXECUTABLE STAGE_DIRECTORY" >&2
  exit 2
fi
executable=$1
stage_directory=$2
[[ -x "$executable" ]] || { echo "missing executable: $executable" >&2; exit 1; }
if [[ -e "$stage_directory" ]]; then
  shopt -s nullglob dotglob
  entries=("$stage_directory"/*)
  [[ -d "$stage_directory" && ${#entries[@]} == 0 ]] || { echo "stage directory must be empty: $stage_directory" >&2; exit 1; }
  shopt -u nullglob dotglob
fi

# The core library anchors the directory: every other Swift runtime library the
# executable needs is installed beside it.
core=libswiftCore.so
runtime_directory=

# 1. What this executable resolved at link time.
if command -v ldd >/dev/null 2>&1; then
  resolved=$(ldd "$executable" 2>/dev/null | awk -v core="$core" '$1 == core && $2 == "=>" { print $3; exit }')
  [[ -z "$resolved" || ! -e "$resolved" ]] || runtime_directory=$(dirname "$resolved")
fi

# 2. What the toolchain reports. Tolerant of pretty-printed or compact JSON.
if [[ -z "$runtime_directory" ]] && command -v swiftc >/dev/null 2>&1; then
  while read -r candidate; do
    [[ -f "$candidate/$core" ]] || continue
    runtime_directory=$candidate
    break
  done < <(swiftc -print-target-info 2>/dev/null \
    | tr ',' '\n' \
    | sed -n '/runtimeLibraryPaths/,$p' \
    | grep -o '"/[^"]*"' \
    | tr -d '"')
fi

# 3. Layouts shipped by past and present toolchain images.
if [[ -z "$runtime_directory" ]]; then
  for candidate in \
    /usr/lib/swift/linux \
    /usr/lib/swift/linux/"$(uname -m)" \
    /usr/libexec/swift/linux \
    /usr/local/lib/swift/linux
  do
    [[ -f "$candidate/$core" ]] || continue
    runtime_directory=$candidate
    break
  done
fi

if [[ -z "$runtime_directory" ]]; then
  {
    echo "could not locate $core for $executable"
    echo "-- searched toolchain trees --"
    for root in /usr/lib/swift /usr/libexec/swift /usr/local/lib/swift; do
      [[ -d "$root" ]] || continue
      find "$root" -maxdepth 3 -name "$core" -o -maxdepth 2 -type d | head -40
    done
    echo "-- swiftc --"
    command -v swiftc >/dev/null 2>&1 && swiftc -print-target-info 2>&1 | head -40 || echo "swiftc unavailable"
  } >&2
  exit 1
fi

mkdir -p "$stage_directory"
# -a keeps the versioned symlinks the loader follows.
cp -a "$runtime_directory"/. "$stage_directory"/
[[ -e "$stage_directory/$core" ]] || { echo "staged tree is missing $core" >&2; exit 1; }

# Report anything the executable needs that did not resolve, so a missing
# runtime library fails here rather than at container start.
if command -v ldd >/dev/null 2>&1; then
  missing=$(ldd "$executable" 2>/dev/null | awk '/not found/ { print $1 }' || true)
  if [[ -n "$missing" ]]; then
    echo "unresolved shared libraries for $executable:" >&2
    echo "$missing" >&2
    exit 1
  fi
fi

printf 'Staged the Swift runtime for %s from %s\n' "$executable" "$runtime_directory"
