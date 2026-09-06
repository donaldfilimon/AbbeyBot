#!/usr/bin/env bash
# Real release images + PostgreSQL + real restic, using an encrypted LOCAL repository.
# No provider credentials, production volumes, published host ports, or R2 calls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
FIXTURES="$ROOT/deploy/production/tests/container-restore"
: "${ABBEY_RELEASE_IMAGE:?Run after the release Abbey image is built}"
: "${ABBEY_CADDY_RELEASE_IMAGE:?Run after the release Caddy image is built}"
command -v python3 >/dev/null
command -v flock >/dev/null
RESTORE_GATE_REAL_DOCKER="$(command -v docker)"
"$RESTORE_GATE_REAL_DOCKER" info >/dev/null
"$RESTORE_GATE_REAL_DOCKER" image inspect "$ABBEY_RELEASE_IMAGE" "$ABBEY_CADDY_RELEASE_IMAGE" >/dev/null
RESTORE_GATE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/abbey-real-restore.XXXXXX")"
RESTORE_GATE_ROOT="$(cd "$RESTORE_GATE_ROOT" && pwd -P)"
RESTORE_GATE_ID="restore-gate-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:16])')"
RESTORE_GATE_RESTIC_IMAGE=restic/restic:0.18.0
RESTORE_GATE_ABBEY_IMAGE="$ABBEY_RELEASE_IMAGE"
RESTORE_GATE_CADDY_IMAGE="$ABBEY_CADDY_RELEASE_IMAGE"
export RESTORE_GATE_ROOT RESTORE_GATE_ID RESTORE_GATE_REAL_DOCKER RESTORE_GATE_RESTIC_IMAGE
export RESTORE_GATE_ABBEY_IMAGE RESTORE_GATE_CADDY_IMAGE

mkdir -p "$RESTORE_GATE_ROOT/production/scripts" "$RESTORE_GATE_ROOT/bin"
cp "$ROOT/deploy/production/scripts/"* "$RESTORE_GATE_ROOT/production/scripts/"
cp "$FIXTURES/compose.yml" "$FIXTURES/Caddyfile" "$RESTORE_GATE_ROOT/production/"
cp "$FIXTURES/shim.py" "$RESTORE_GATE_ROOT/bin/docker"
cp "$FIXTURES/shim.py" "$RESTORE_GATE_ROOT/bin/restic"
chmod +x "$RESTORE_GATE_ROOT/bin/"*
export PATH="$RESTORE_GATE_ROOT/bin:$PATH"
COMPOSE=(docker compose --project-directory "$RESTORE_GATE_ROOT/production" \
  --env-file "$RESTORE_GATE_ROOT/production/.env" --file "$RESTORE_GATE_ROOT/production/compose.yml")
cleanup() {
  local code=$? resource
  trap - EXIT
  "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || code=1
  # Validation resources have this random gate prefix even if a child trap was interrupted.
  while IFS= read -r resource; do
    [[ -z "$resource" ]] || "$RESTORE_GATE_REAL_DOCKER" rm --force "$resource" >/dev/null || code=1
  done < <("$RESTORE_GATE_REAL_DOCKER" ps --all --filter "name=^/${RESTORE_GATE_ID}-abbey-restore-check-" --format '{{.ID}}')
  while IFS= read -r resource; do
    [[ -z "$resource" ]] || "$RESTORE_GATE_REAL_DOCKER" volume rm "$resource" >/dev/null || code=1
  done < <("$RESTORE_GATE_REAL_DOCKER" volume ls --filter "name=^${RESTORE_GATE_ID}-abbey-restore-check-" --format '{{.Name}}')
  # Archive files created by root inside the release image may be root-owned.
  "$RESTORE_GATE_REAL_DOCKER" run --rm --network none --user 0:0 \
    --volume "$RESTORE_GATE_ROOT:/gate" --entrypoint /bin/sh "$ABBEY_RELEASE_IMAGE" \
    -c 'find /gate -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' >/dev/null || code=1
  rmdir "$RESTORE_GATE_ROOT" || code=1
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
python3 - "$RESTORE_GATE_ROOT" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
(root/'production/.env').write_text('ABBEYBOT_IMAGE=ghcr.io/donaldfilimon/abbeybot@sha256:'+'1'*64+'\nABBEY_CADDY_IMAGE=ghcr.io/donaldfilimon/abbeybot-caddy@sha256:'+'2'*64+'\n')
(root/'password').write_text('synthetic-local-release-password\n')
(root/'production/.backup.env').write_text('RESTIC_REPOSITORY=s3:https://fixture.r2.cloudflarestorage.com/unused\nAWS_ACCESS_KEY_ID=synthetic-fixture\nAWS_SECRET_ACCESS_KEY=synthetic-fixture\nRESTIC_PASSWORD_FILE='+str(root/'password')+'\n')
PY

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$FIXTURES" -p 'test_*.py'
"$RESTORE_GATE_REAL_DOCKER" pull postgres:16.15-alpine3.23
"$RESTORE_GATE_REAL_DOCKER" pull "$RESTORE_GATE_RESTIC_IMAGE"
restic init
"${COMPOSE[@]}" up --detach --wait --wait-timeout 180
# Test SQL is a dedicated table in this gate's disposable database.
"${COMPOSE[@]}" exec --no-TTY db psql --username=abbey --dbname=abbeybot --set=ON_ERROR_STOP=1 \
  --command="CREATE TABLE release_restore_probe (value text NOT NULL); INSERT INTO release_restore_probe VALUES ('before');"
write_probes() {
  local value="$1" store
  "${COMPOSE[@]}" exec --no-TTY db psql --username=abbey --dbname=abbeybot --set=ON_ERROR_STOP=1 \
    --command="UPDATE release_restore_probe SET value = '$value';" >/dev/null
  for store in quasar state; do
    docker run --rm --network none --user 0:0 --volume "abbeybot_$store:/probe" \
      --entrypoint /bin/sh "$ABBEY_RELEASE_IMAGE" -ceu \
      'printf "%s" "$1" > /probe/release-restore-probe; chown 10001:10001 /probe/release-restore-probe' gate-probe "$value"
  done
}
assert_probes() {
  local value="$1" observed store
  observed="$("${COMPOSE[@]}" exec --no-TTY db psql --username=abbey --dbname=abbeybot --tuples-only --no-align \
    --command='SELECT value FROM release_restore_probe;')"
  [[ "$observed" = "$value" ]] || { echo "RESTORE_CONTAINER_FAIL: database probe mismatch" >&2; return 1; }
  for store in quasar state; do
    observed="$(docker run --rm --network none --volume "abbeybot_$store:/probe:ro" \
      --entrypoint /bin/cat "$ABBEY_RELEASE_IMAGE" /probe/release-restore-probe)"
    [[ "$observed" = "$value" ]] || { echo "RESTORE_CONTAINER_FAIL: $store probe mismatch" >&2; return 1; }
  done
  "${COMPOSE[@]}" exec --no-TTY caddy wget --quiet --output-document=- http://127.0.0.1:8080/health \
    | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "ok"'
}

write_probes before
checkpoint="$RESTORE_GATE_ROOT/checkpoint-before"
bash "$RESTORE_GATE_ROOT/production/scripts/backup.sh" "$checkpoint"
assert_probes before
restic check --read-data

write_probes after
# Real extraction finishes first, then the shim returns a single failure. The
# unchanged production EXIT recovery must restore the pre-restore SQL and files.
touch "$RESTORE_GATE_ROOT/fail-state-once"
if bash "$RESTORE_GATE_ROOT/production/scripts/restore.sh" "$checkpoint"; then
  echo "RESTORE_CONTAINER_FAIL: injected extraction failure was ignored" >&2
  exit 1
fi
[[ ! -e "$RESTORE_GATE_ROOT/fail-state-once" ]] || { echo "RESTORE_CONTAINER_FAIL: injection never reached extraction" >&2; exit 1; }
assert_probes after

# Corrupt-but-checksummed dump must fail actual disposable pg_restore before stop.
cp -R "$checkpoint" "$RESTORE_GATE_ROOT/invalid-checkpoint"
printf 'invalid postgres dump\n' >"$RESTORE_GATE_ROOT/invalid-checkpoint/postgres.dump"
python3 "$ROOT/deploy/production/scripts/backup-format.py" seal "$RESTORE_GATE_ROOT/invalid-checkpoint"
stops_before="$(wc -l <"$RESTORE_GATE_ROOT/stop-events")"
if bash "$RESTORE_GATE_ROOT/production/scripts/restore.sh" "$RESTORE_GATE_ROOT/invalid-checkpoint"; then
  echo "RESTORE_CONTAINER_FAIL: corrupt dump passed real validation" >&2
  exit 1
fi
[[ "$(wc -l <"$RESTORE_GATE_ROOT/stop-events")" = "$stops_before" ]]
assert_probes after

# Retrieve the encrypted snapshot through real restic before the successful restore.
restic restore latest --path "$checkpoint" --target "$RESTORE_GATE_ROOT/retrieved" --verify
retrieved="$RESTORE_GATE_ROOT/retrieved$checkpoint"
python3 "$ROOT/deploy/production/scripts/backup-format.py" verify "$retrieved"
bash "$RESTORE_GATE_ROOT/production/scripts/restore.sh" "$retrieved"
assert_probes before

echo "RESTORE_CONTAINER_GREEN: real PostgreSQL/release images, three-store rollback, corrupt-dump refusal, encrypted LOCAL restic retrieval"
echo "RESTORE_CONTAINER_LIMIT: local repository and unpublished image aliases; no R2, GHCR pull authentication, external HTTPS, or provider acceptance"
