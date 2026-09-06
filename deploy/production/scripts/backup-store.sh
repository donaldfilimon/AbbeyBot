#!/usr/bin/env bash
# Explicit repository setup/inspection/retrieval. Never deletes remote snapshots.
set -euo pipefail
# shellcheck source=SCRIPTDIR/_lib.sh
source "$(cd "$(dirname "$0")" && pwd -P)/_lib.sh"
umask 077
[[ $# -ge 1 ]] || { echo "usage: $0 init|check|snapshots|fetch <snapshot> <new-directory>" >&2; exit 2; }
action="$1"; shift
lock_operation
case "$action" in
  init|check|snapshots)
    [[ $# = 0 ]] || { echo "unexpected arguments" >&2; exit 2; }
    require_backup "$action"
    restic_run "$action"
    ;;
  fetch)
    [[ $# = 2 && "$1" =~ ^([0-9a-f]{8,64}|latest)$ ]] || { echo "fetch requires snapshot ID (or latest) and a new directory" >&2; exit 2; }
    require_backup
    mkdir "$2"
    destination="$(cd "$2" && pwd -P)"
    restic_run restore "$1" --target "$destination" --verify
    echo "snapshot retrieved under $destination; locate its SHA256SUMS directory for restore.sh"
    ;;
  *) echo "unknown backup-store action" >&2; exit 2 ;;
esac
