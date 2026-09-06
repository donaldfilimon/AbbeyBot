#!/bin/sh
# Locate packaged resources without renaming the bundle expected by Bundle.module.
set -eu
module="${1:?module required}"
base="${2:-/app}"
case "$module" in
    AbbeyCore) marker=KnowledgeSnapshot ;;
    AbbeyQuasarKit) marker=next-site.manifest.json ;;
    AbbeyServer) marker=Resources/Public/index.html ;;
    *) echo 'unknown release resource module' >&2; exit 1 ;;
esac
found=
for suffix in bundle resources; do
    for interior in '' /Contents/Resources; do
        candidate="$base/AbbeyBot_${module}.${suffix}${interior}"
        if [ -e "$candidate/$marker" ]; then
            [ -z "$found" ] || { echo 'ambiguous release resource bundle' >&2; exit 1; }
            found="$candidate"
        fi
    done
done
[ -n "$found" ] || { echo "missing release resource bundle for $module" >&2; exit 1; }
printf '%s\n' "$found"
