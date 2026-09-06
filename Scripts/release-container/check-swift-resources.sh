#!/usr/bin/env bash
# Compile a tiny package with the actual image toolchain, then relocate it before
# reading Bundle.module. This catches output-layout changes before the full build.
set -euo pipefail
script_directory=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/AbbeyBot.resource-staging.build.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
if (( $# == 0 )); then set -- swift; fi
unset TOOLCHAINS PACKAGE_RESOURCE_BUNDLE_PATH PACKAGE_RESOURCE_BUNDLE_URL
build_arguments=(--package-path "$script_directory/swift-resource-fixture" --build-path "$scratch/build" -c release --product resource-probe)
if [[ -n "${ABBEY_RESOURCE_FIXTURE_BUILD_SYSTEM:-}" ]]; then
  build_arguments+=(--build-system "$ABBEY_RESOURCE_FIXTURE_BUILD_SYSTEM")
fi
"$@" build "${build_arguments[@]}"
bin_directory=$("$@" build "${build_arguments[@]}" --show-bin-path)
bash "$script_directory/stage-products.sh" "$bin_directory" "$scratch/stage" resource-probe AbbeyResourceFixture_ResourceLibrary
# Hide the compiled-in fallback path used by older SwiftPM accessors.
mv "$scratch/build" "$scratch/build-hidden"
result=$(cd "$scratch/stage" && ./resource-probe)
[[ "$result" == 'relocated-resource-ok' ]] || { echo "unexpected resource probe result: $result" >&2; exit 1; }
echo 'Relocated Swift Bundle.module resource probe passed.'
