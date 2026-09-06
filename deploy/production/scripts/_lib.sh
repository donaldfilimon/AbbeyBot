#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENV_FILE="$DEPLOY_DIR/.env"
COMPOSE_FILE="$DEPLOY_DIR/compose.yml"
COMPOSE=(env -u ABBEYBOT_IMAGE -u ABBEY_CADDY_IMAGE docker compose --project-directory "$DEPLOY_DIR" --env-file "$ENV_FILE" --file "$COMPOSE_FILE")

require_runtime() {
  command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
  command -v python3 >/dev/null || { echo "Python 3.11+ is required" >&2; exit 1; }
  python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
  docker compose version >/dev/null
  docker info >/dev/null
  [[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE; copy .env.example and set required values" >&2; exit 1; }
  "${COMPOSE[@]}" config --quiet
}

env_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "$ENV_FILE"
}

file_value() {
  local file="$1"
  local key="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "$file"
}

require_digest_ref() {
  local value="$1"
  local image="$2"
  [[ "$value" =~ ^ghcr\.io/donaldfilimon/${image}@sha256:[0-9a-f]{64}$ ]] || {
    echo "expected immutable ghcr.io/donaldfilimon/${image}@sha256:<64 lowercase hex>" >&2
    exit 1
  }
}

# The environment describes intent; checkpoint labels must describe running bytes.
# Compare Docker's immutable image IDs, not mutable tags or Config.Image text.
require_running_images() {
  local abbey_ref="$1" caddy_ref="$2" service reference container observed expected
  for service in abbey caddy; do
    if [[ "$service" = abbey ]]; then reference="$abbey_ref"; else reference="$caddy_ref"; fi
    container="$("${COMPOSE[@]}" ps --quiet "$service")" || return
    [[ -n "$container" && "$container" != *$'\n'* ]] || {
      echo "$service must have exactly one running container before checkpointing" >&2; return 1;
    }
    # Inspect only nonsecret fields; never emit container environment/configuration.
    expected="$(docker image inspect --format '{{.Id}}' "$reference")" || {
      echo "$service configured digest is not locally inspectable; refusing checkpoint" >&2; return 1;
    }
    [[ "$expected" =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo "$service configured digest resolved to an invalid image identity" >&2; return 1;
    }
    observed="$(docker inspect --format '{{.State.Running}} {{.Image}}' "$container")" || return
    [[ "$observed" = "true $expected" ]] || {
      echo "$service running image does not match its configured digest; reconcile .env with the running installation before continuing" >&2
      return 1
    }
  done
}

set_env_value() {
  local key="$1"
  local value="$2"
  local temporary
  temporary="$(mktemp "$DEPLOY_DIR/.env.tmp.XXXXXX")"
  awk -F= -v key="$key" -v value="$value" '
    BEGIN { replaced=0 }
    $1 == key { print key "=" value; replaced=1; next }
    { print }
    END { if (!replaced) print key "=" value }
  ' "$ENV_FILE" > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$ENV_FILE"
}

wait_healthy() {
  local service="$1"
  local deadline=$((SECONDS + 180))
  local container status
  while (( SECONDS < deadline )); do
    container="$("${COMPOSE[@]}" ps --quiet "$service")" || return
    if [[ -n "$container" ]]; then
      status="$(docker inspect --format '{{if not .State.Running}}{{.State.Status}}{{else if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container")" || return
      case "$status" in
        healthy|running) return 0 ;;
        unhealthy|exited|dead) echo "$service entered $status state" >&2; return 1 ;;
      esac
    fi
    sleep 2
  done
  echo "$service did not become healthy within 180 seconds" >&2
  return 1
}

stop_application() {
  "${COMPOSE[@]}" stop caddy abbey
}

start_application() {
  "${COMPOSE[@]}" up --detach --pull never db abbey || return
  wait_healthy abbey || return
  "${COMPOSE[@]}" up --detach --pull never caddy || return
  wait_healthy caddy || return
}

# Serializes bootstrap, upgrades, backups and restores for this deployment.
lock_operation() {
  command -v flock >/dev/null || { echo "flock (util-linux) is required" >&2; return 1; }
  exec 9>"$DEPLOY_DIR/.operation.lock"
  flock --nonblock 9 || { echo "another deployment operation is active" >&2; return 1; }
}

require_backup() {
  command -v restic >/dev/null || { echo "restic is required for encrypted off-host backups" >&2; return 1; }
  local config="$DEPLOY_DIR/.backup.env"
  [[ -f "$config" ]] || { echo "missing .backup.env; refusing operation without off-host backups" >&2; return 1; }
  python3 - "$config" <<'PY'
import os, stat, sys
p=sys.argv[1]
if os.path.islink(p) or os.stat(p).st_mode & 0o077:
    raise SystemExit('backup configuration must be a private regular file (mode 0600)')
PY
  backup_repository="$(file_value "$config" RESTIC_REPOSITORY)"
  backup_password_file="$(file_value "$config" RESTIC_PASSWORD_FILE)"
  backup_access_id="$(file_value "$config" AWS_ACCESS_KEY_ID)"
  backup_secret="$(file_value "$config" AWS_SECRET_ACCESS_KEY)"
  [[ "$backup_repository" =~ ^s3:https://[a-zA-Z0-9.-]+\.r2\.cloudflarestorage\.com/[a-zA-Z0-9._/-]+$ ]] || {
    echo "RESTIC_REPOSITORY must be an HTTPS Cloudflare R2 bucket repository" >&2; return 1;
  }
  [[ -n "$backup_access_id" && -n "$backup_secret" && "$backup_password_file" = /* && -s "$backup_password_file" ]] || {
    echo "backup credentials and an absolute nonempty password file are required" >&2; return 1;
  }
  python3 - "$backup_password_file" <<'PY'
import os, stat, sys
p=sys.argv[1]
if os.path.islink(p) or not stat.S_ISREG(os.stat(p).st_mode) or os.stat(p).st_mode & 0o077:
    raise SystemExit('restic password file must be a private regular file (mode 0600)')
PY
  # A missing repository must be initialized explicitly, never silently replaced.
  if [[ "${1:-}" != init ]]; then restic_run cat config >/dev/null; fi
}

restic_run() {
  env -u AWS_SESSION_TOKEN -u RESTIC_PASSWORD -u RESTIC_PASSWORD_COMMAND -u RESTIC_REPOSITORY_FILE \
    RESTIC_REPOSITORY="$backup_repository" RESTIC_PASSWORD_FILE="$backup_password_file" \
    AWS_ACCESS_KEY_ID="$backup_access_id" AWS_SECRET_ACCESS_KEY="$backup_secret" \
    AWS_DEFAULT_REGION=auto restic "$@"
}

new_checkpoint() {
  mkdir -p "$DEPLOY_DIR/backups"
  mktemp -d "$DEPLOY_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)-$1.XXXXXX"
}

# Caller keeps Abbey stopped from before this snapshot through the data mutation.
write_checkpoint() {
  local directory="$1" abbey="$2" caddy="$3"
  "${COMPOSE[@]}" up --detach db || return
  wait_healthy db || return
  # Variables below expand inside Postgres, never in the host shell.
  # shellcheck disable=SC2016
  "${COMPOSE[@]}" exec --no-TTY db sh -eu -c \
    'exec pg_dump --format=custom --username="$POSTGRES_USER" "$POSTGRES_DB"' >"$directory/postgres.dump" || return
  local store archive
  for store in quasar state; do
    archive="$store.tar.gz"
    docker run --rm --user 0:0 --entrypoint /bin/tar \
      --volume "abbeybot_$store:/source:ro" --volume "$directory:/backup" \
      "$abbey" --exclude=node_modules --exclude=.next -C /source -czf "/backup/$archive" . || return
  done
  printf 'ABBEYBOT_IMAGE=%s\nABBEY_CADDY_IMAGE=%s\nCREATED_AT=%s\n' \
    "$abbey" "$caddy" "$(date -u +%Y%m%dT%H%M%SZ)" >"$directory/manifest.env"
  python3 "$DEPLOY_DIR/scripts/backup-format.py" seal "$directory" || return
  restic_run backup --tag abbeybot-checkpoint -- "$directory" || return
}

# Every command explicitly propagates failure because rollback calls this from a conditional.
restore_data() {
  local directory="$1" image="$2"
  "${COMPOSE[@]}" up --detach db || return
  wait_healthy db || return
  # Variables below expand inside Postgres, never in the host shell.
  # shellcheck disable=SC2016
  "${COMPOSE[@]}" exec --no-TTY db sh -eu -c '
    dropdb --if-exists --force --username="$POSTGRES_USER" "$POSTGRES_DB"
    createdb --username="$POSTGRES_USER" --owner="$POSTGRES_USER" "$POSTGRES_DB"
  ' || return
  # Variables below expand inside Postgres, never in the host shell.
  # shellcheck disable=SC2016
  "${COMPOSE[@]}" exec --no-TTY db sh -eu -c \
    'exec pg_restore --exit-on-error --no-owner --no-acl --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' \
    <"$directory/postgres.dump" || return
  local store
  for store in quasar state; do
    docker run --rm --user 0:0 --entrypoint /bin/sh \
      --volume "abbeybot_$store:/restore" --volume "$directory:/backup:ro" "$image" -ceu '
        find /restore -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        tar -xzf "/backup/$1.tar.gz" -C /restore
        chown -R 10001:10001 /restore
      ' abbey-restore "$store" || return
  done
}

# Validate both restores without touching live volumes or the running database.
validate_restore() (
  set -euo pipefail
  local directory="$1" image="$2"
  local suffix="abbey-restore-check-$$-$RANDOM" container="" volume=""
  # Invoked by the EXIT trap.
  # shellcheck disable=SC2329
  cleanup_validation() {
    local code=$?
    trap - EXIT
    if [[ -n "$container" ]]; then docker rm --force "$container" >/dev/null || code=1; fi
    if [[ -n "$volume" ]]; then docker volume rm "$volume" >/dev/null || code=1; fi
    exit "$code"
  }
  trap cleanup_validation EXIT
  volume="$(docker volume create "$suffix")"
  for archive in quasar state; do
    docker run --rm --network none --user 0:0 --entrypoint /bin/sh \
      --volume "$volume:/validation" --volume "$directory:/backup:ro" \
      "$image" -ceu 'mkdir "/validation/$1"; tar -xzf "/backup/$1.tar.gz" -C "/validation/$1"' abbey-validate "$archive"
  done
  container="$suffix"
  docker run --detach --name "$container" --network none --memory 1g --cpus 1 --pids-limit 128 \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    --tmpfs /var/lib/postgresql/data:rw,nosuid,nodev \
    "$POSTGRES_IMAGE" >/dev/null
  ready=0
  for _ in {1..60}; do
    if docker exec "$container" pg_isready --username=postgres >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  [[ "$ready" = 1 ]] || { echo "disposable Postgres failed readiness" >&2; exit 1; }
  docker exec "$container" createdb --username=postgres validation
  docker exec --interactive "$container" pg_restore --exit-on-error --no-owner --no-acl \
    --username=postgres --dbname=validation <"$directory/postgres.dump"
)

POSTGRES_IMAGE=postgres:16.15-alpine3.23
