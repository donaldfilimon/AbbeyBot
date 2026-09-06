#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/_lib.sh
source "$(cd "$(dirname "$0")" && pwd -P)/_lib.sh"
umask 077
bootstrap=0
if [[ "${1:-}" = --bootstrap ]]; then bootstrap=1; shift; fi
[[ $# = 2 ]] || { echo "usage: $0 [--bootstrap] <Abbey digest reference> <Caddy digest reference>" >&2; exit 2; }
require_runtime
lock_operation
next_abbey="$1"; next_caddy="$2"
require_digest_ref "$next_abbey" abbeybot
require_digest_ref "$next_caddy" abbeybot-caddy
current_abbey="$(env_value ABBEYBOT_IMAGE)"
current_caddy="$(env_value ABBEY_CADDY_IMAGE)"
require_backup
if (( bootstrap )); then
  existing_volumes="$(docker volume ls --filter 'name=^abbeybot_(postgres|quasar|state)$' --format '{{.Name}}')"
  existing_containers="$("${COMPOSE[@]}" ps --all --quiet)"
  [[ -z "$existing_volumes" && -z "$existing_containers" ]] || {
    echo "bootstrap requires absent Abbey containers and data volumes; use upgrade or restore" >&2; exit 1;
  }
else
  require_digest_ref "$current_abbey" abbeybot
  require_digest_ref "$current_caddy" abbeybot-caddy
  require_running_images "$current_abbey" "$current_caddy"
fi
# Pull exact requested replacements before any downtime or configuration changes.
docker pull "$next_abbey"
docker pull "$next_caddy"
docker pull "$POSTGRES_IMAGE"
checkpoint=""
interrupted=0
mutated=0
recover_deploy() {
  local code=$?
  trap - EXIT
  if (( interrupted )); then
    if (( mutated )); then
      stop_application || { echo "cannot stop failed deployment; manual recovery required" >&2; exit 1; }
      set_env_value ABBEYBOT_IMAGE "$current_abbey"
      set_env_value ABBEY_CADDY_IMAGE "$current_caddy"
      if [[ -n "$checkpoint" ]]; then
        if ! restore_data "$checkpoint" "$current_abbey"; then
          echo "deployment rollback failed; application remains stopped; checkpoint: $checkpoint" >&2; exit 1
        fi
      fi
    fi
    if (( ! bootstrap )); then
      if ! start_application; then
        stop_application || echo "failed to stop unhealthy rollback; manual intervention required" >&2
        echo "rollback health failed; manual recovery required: $checkpoint" >&2
        exit 1
      fi
    fi
  fi
  exit "$code"
}
trap recover_deploy EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
interrupted=1
if (( ! bootstrap )); then
  stop_application
  checkpoint="$(new_checkpoint pre-upgrade)"
  write_checkpoint "$checkpoint" "$current_abbey" "$current_caddy"
fi
mutated=1
set_env_value ABBEYBOT_IMAGE "$next_abbey"
set_env_value ABBEY_CADDY_IMAGE "$next_caddy"
start_application
trap - EXIT
echo "deployed immutable images: $next_abbey $next_caddy"
echo "External HTTPS, provider and Discord acceptance remain separate checks."
