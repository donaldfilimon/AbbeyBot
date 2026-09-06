#!/usr/bin/env bash
# Preserve generated resource bundle names: Bundle.module embeds these names.
set -euo pipefail
if (( $# < 4 )); then
  echo "usage: $0 BIN_DIRECTORY STAGE_DIRECTORY EXECUTABLE RESOURCE_STEM..." >&2
  exit 2
fi
bin_directory=$1
stage_directory=$2
executable=$3
shift 3
[[ -x "$bin_directory/$executable" ]] || { echo "missing executable: $bin_directory/$executable" >&2; exit 1; }
shopt -s nullglob dotglob
if [[ -e "$stage_directory" ]]; then
  entries=("$stage_directory"/*)
  [[ -d "$stage_directory" && ${#entries[@]} == 0 ]] || { echo "stage directory must be empty: $stage_directory" >&2; exit 1; }
fi
for stem in "$@"; do
  matches=()
  for suffix in bundle resources; do
    [[ ! -d "$bin_directory/$stem.$suffix" ]] || matches+=("$bin_directory/$stem.$suffix")
  done
  [[ ${#matches[@]} == 1 ]] || { echo "expected one generated resource bundle for $stem, found ${#matches[@]}" >&2; exit 1; }
done
mkdir -p "$stage_directory"
cp "$bin_directory/$executable" "$stage_directory/"
# Include dependency resource bundles as well as the required package bundles.
for bundle in "$bin_directory"/*.bundle "$bin_directory"/*.resources; do
  [[ -d "$bundle" ]] || continue
  cp -RL "$bundle" "$stage_directory/"
done
printf 'Staged %s and its resource bundles from %s\n' "$executable" "$bin_directory"
