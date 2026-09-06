#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/_lib.sh
source "$(cd "$(dirname "$0")" && pwd -P)/_lib.sh"
umask 077
[[ $# = 1 ]] || { echo "usage: $0 /absolute/path/to/backup" >&2; exit 2; }
require_runtime
lock_operation
require_backup
# Freeze caller-owned input to prevent archive changes between validation and extraction.
checkpoint=""
interrupted=0
mutated=0
current_abbey="$(env_value ABBEYBOT_IMAGE)"
current_caddy="$(env_value ABBEY_CADDY_IMAGE)"
require_digest_ref "$current_abbey" abbeybot
require_digest_ref "$current_caddy" abbeybot-caddy
require_running_images "$current_abbey" "$current_caddy"
staging="$(mktemp -d "$DEPLOY_DIR/.restore-input.XXXXXX")"
recover_restore() {
  local code=$?
  trap - EXIT
  if (( interrupted )); then
    if (( mutated )); then
      if ! stop_application; then echo "failed to stop restore; manual recovery required: $checkpoint" >&2; exit 1; fi
      set_env_value ABBEYBOT_IMAGE "$current_abbey"
      set_env_value ABBEY_CADDY_IMAGE "$current_caddy"
      if ! restore_data "$checkpoint" "$current_abbey"; then
        echo "rollback failed; application remains stopped; checkpoint: $checkpoint" >&2; exit 1
      fi
    fi
    if ! start_application; then
      stop_application || echo "failed to stop unhealthy recovery; manual intervention required" >&2
      echo "recovery health failed; checkpoint: $checkpoint" >&2
      code=1
    fi
  fi
  rm -rf -- "$staging"
  exit "$code"
}
trap recover_restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for name in postgres.dump quasar.tar.gz state.tar.gz manifest.env SHA256SUMS; do
  [[ -f "$1/$name" && ! -L "$1/$name" ]] || { echo "backup requires regular $name" >&2; exit 1; }
  cp "$1/$name" "$staging/$name"
done
python3 "$DEPLOY_DIR/scripts/backup-format.py" verify "$staging"
restore_abbey="$(file_value "$staging/manifest.env" ABBEYBOT_IMAGE)"
restore_caddy="$(file_value "$staging/manifest.env" ABBEY_CADDY_IMAGE)"
require_digest_ref "$restore_abbey" abbeybot
require_digest_ref "$restore_caddy" abbeybot-caddy
docker pull "$restore_abbey"
docker pull "$restore_caddy"
docker pull "$POSTGRES_IMAGE"
validate_restore "$staging" "$restore_abbey"
# Do not reopen ingress between the checkpoint and the restore.
interrupted=1
stop_application
checkpoint="$(new_checkpoint pre-restore)"
write_checkpoint "$checkpoint" "$current_abbey" "$current_caddy"
mutated=1
set_env_value ABBEYBOT_IMAGE "$restore_abbey"
set_env_value ABBEY_CADDY_IMAGE "$restore_caddy"
restore_data "$staging" "$restore_abbey"
start_application
interrupted=0
rm -rf -- "$staging"
trap - EXIT
echo "restored validated backup; retained checkpoint: $checkpoint"
echo "External HTTPS and provider behavior still require separate acceptance checks."
