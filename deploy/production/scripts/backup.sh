#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/_lib.sh
source "$(cd "$(dirname "$0")" && pwd -P)/_lib.sh"
umask 077
require_runtime
lock_operation
require_backup
[[ $# -le 1 ]] || { echo "usage: $0 [new-backup-directory]" >&2; exit 2; }
abbey_image="$(env_value ABBEYBOT_IMAGE)"
caddy_image="$(env_value ABBEY_CADDY_IMAGE)"
require_digest_ref "$abbey_image" abbeybot
require_digest_ref "$caddy_image" abbeybot-caddy
require_running_images "$abbey_image" "$caddy_image"
if [[ $# = 1 ]]; then
  # Never overwrite an existing backup, even an incomplete one.
  mkdir "$1"
  backup_dir="$(cd "$1" && pwd -P)"
else
  backup_dir="$(new_checkpoint backup)"
fi
restart_after_backup() {
  local code=$?
  trap - EXIT
  if ! start_application; then echo "backup recovery could not restart application" >&2; code=1; fi
  exit "$code"
}
trap restart_after_backup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stop_application
write_checkpoint "$backup_dir" "$abbey_image" "$caddy_image"
start_application
trap - EXIT
echo "local and encrypted off-host backup completed: $backup_dir"
