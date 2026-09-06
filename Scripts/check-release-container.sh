#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ABBEY_RELEASE_IMAGE="${ABBEY_RELEASE_IMAGE:-abbeybot-release-gate:local}"
ABBEY_CADDY_RELEASE_IMAGE="${ABBEY_CADDY_RELEASE_IMAGE:-abbeybot-caddy-release-gate:local}"
ABBEY_RELEASE_SKIP_BUILD="${ABBEY_RELEASE_SKIP_BUILD:-0}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "RELEASE_CONTAINER_FAIL: a running Docker daemon is required" >&2
    exit 1
fi

GATE_ID="release-gate-$$"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/abbey-release-container.XXXXXX")"
SERVER_CONTAINER="${GATE_ID}-server"
PREVIEW_CONTAINER="${GATE_ID}-preview"
PROVIDER_CONTAINER="${GATE_ID}-provider"
PROXY_FIXTURE_CONTAINER="${GATE_ID}-proxy-fixture"
CADDY_CONTAINER="${GATE_ID}-caddy"
GATE_NETWORK="${GATE_ID}-network"

cleanup() {
    docker rm -f "$SERVER_CONTAINER" "$PREVIEW_CONTAINER" "$PROVIDER_CONTAINER" \
        "$PROXY_FIXTURE_CONTAINER" "$CADDY_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$GATE_NETWORK" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

wait_for_http() {
    local container="$1"
    local url="$2"
    local output="$3"
    local description="$4"
    local _

    for _ in $(seq 1 90); do
        if curl --fail --silent --show-error "$url" >"$output" 2>/dev/null; then
            return 0
        fi
        if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
            echo "RELEASE_CONTAINER_FAIL: ${description} exited before it became ready" >&2
            docker logs "$container" >&2 || true
            return 1
        fi
        sleep 1
    done

    echo "RELEASE_CONTAINER_FAIL: timed out waiting for ${description}" >&2
    docker logs "$container" >&2 || true
    return 1
}

published_port() {
    local container="$1"
    local container_port="$2"
    local endpoint
    endpoint="$(docker port "$container" "${container_port}/tcp" | head -1)"
    test -n "$endpoint"
    printf '%s\n' "${endpoint##*:}"
}

echo "======== 1/7 build release images ========"
if [[ "$ABBEY_RELEASE_SKIP_BUILD" == "1" ]]; then
    docker image inspect "$ABBEY_RELEASE_IMAGE" >/dev/null
    docker image inspect "$ABBEY_CADDY_RELEASE_IMAGE" >/dev/null
else
    docker build \
        --build-arg "ABBEY_VCS_REF=${GITHUB_SHA:-local}" \
        --tag "$ABBEY_RELEASE_IMAGE" \
        --file Dockerfile \
        .
    docker build \
        --tag "$ABBEY_CADDY_RELEASE_IMAGE" \
        --file deploy/production/caddy/Dockerfile \
        deploy/production/caddy
fi

echo "======== 2/7 assert runtime and bundled resources ========"
IMAGE_PLATFORM_USER="$(docker image inspect --format '{{.Os}}/{{.Architecture}} {{.Config.User}}' "$ABBEY_RELEASE_IMAGE")"
case "$IMAGE_PLATFORM_USER" in
    linux/*' abbey'|linux/*' 10001') ;;
    *)
        echo "RELEASE_CONTAINER_FAIL: unexpected image platform/user: ${IMAGE_PLATFORM_USER}" >&2
        exit 1
        ;;
esac
docker run --rm --entrypoint /bin/sh "$ABBEY_RELEASE_IMAGE" -c '
    set -eu
    test "$(id -u)" = 10001
    test "$(bun --version)" = 1.3.14
    test "$(node -p process.versions.bun)" = "$(bun --version)"
    test -x /app/AbbeyBot
    test -d /app/AbbeyBot_AbbeyCore.resources
    test -d /app/AbbeyBot_AbbeyQuasarKit.resources/next-site
    test -f /app/AbbeyBot_AbbeyQuasarKit.resources/next-site.manifest.json
    test -f /app/AbbeyBot_AbbeyServer.resources/Resources/Views/status.leaf
    test -f /app/AbbeyBot_AbbeyServer.resources/Resources/Public/index.html
'
docker run --rm --read-only --network none \
    --volume "$ROOT/Scripts/release-container:/release-fixtures:ro" \
    --entrypoint bun "$ABBEY_RELEASE_IMAGE" /release-fixtures/test-fixtures.mjs
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Scripts/release-container -p 'test_*.py'

mkdir -p "$WORK_DIR/server/home" "$WORK_DIR/server/quasar" "$WORK_DIR/server/bun-cache" "$WORK_DIR/preview"
chmod -R 0777 "$WORK_DIR/server" "$WORK_DIR/preview"

# Fixture traffic stays on this Docker network. No hosted inference credentials
# enter the gate; the normal provider/router and authenticated API still execute.
docker network create "$GATE_NETWORK" >/dev/null
docker run --detach --init --read-only \
    --name "$PROVIDER_CONTAINER" --network "$GATE_NETWORK" --network-alias release-provider \
    --volume "$ROOT/Scripts/release-container:/release-fixtures:ro" \
    --entrypoint bun "$ABBEY_RELEASE_IMAGE" /release-fixtures/provider.mjs >/dev/null
for _ in $(seq 1 30); do
    if docker exec "$PROVIDER_CONTAINER" curl --fail --silent http://127.0.0.1:8089/health >/dev/null; then break; fi
    sleep 1
done
docker exec "$PROVIDER_CONTAINER" curl --fail --silent http://127.0.0.1:8089/health >/dev/null

run_server() {
    docker rm -f "$SERVER_CONTAINER" >/dev/null 2>&1 || true
    docker run --detach --init --read-only --tmpfs /tmp:rw,nosuid,nodev,size=1g \
        --name "$SERVER_CONTAINER" \
        --network "$GATE_NETWORK" \
        --publish 127.0.0.1::8080 \
        --volume "$ROOT/Scripts/release-container:/release-fixtures:ro" \
        --volume "$WORK_DIR/server:/data" \
        --volume "$WORK_DIR/server/home:/var/lib/abbey/.abbey" \
        --env DATABASE_URL=sqlite:///data/abbey.sqlite \
        --env ABBEY_QUASAR_HOME=/data/quasar \
        --env BUN_INSTALL_CACHE_DIR=/data/bun-cache \
        --env ABBEY_DRY_RUN=1 \
        --env ABBEY_INFERENCE_MODE=remoteCompatible \
        --env ABBEY_REMOTE_ENDPOINT=http://release-provider:8089/v1/chat/completions \
        --env ABBEY_REMOTE_MODEL=abbey-release-fixture \
        --env ABBEY_REMOTE_API_TOKEN=abbey-release-fixture-token \
        --env ABBEY_API_TOKEN=abbey-release-gate-operator-token \
        --env ABBEY_QUASAR_API_TOKEN=abbey-release-gate-quasar-token \
        --env ABBEY_QUASAR_PREVIEW_INTERNAL_TOKEN=abbey-release-gate-internal-token \
        --env ABBEY_QUASAR_PREVIEW_BIND_HOST=0.0.0.0 \
        --env ABBEY_QUASAR_PREVIEW_UPSTREAM_HOST=abbey \
        "$ABBEY_RELEASE_IMAGE" >/dev/null
}

echo "======== 3/7 boot full server with disposable SQLite ========"
run_server
SERVER_PORT="$(published_port "$SERVER_CONTAINER" 8080)"
wait_for_http "$SERVER_CONTAINER" "http://127.0.0.1:${SERVER_PORT}/health" "$WORK_DIR/health-first.json" "Abbey server"
python3 - "$WORK_DIR/health-first.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
assert payload.get("status") == "ok", payload
PY
curl --fail --silent --show-error \
    --header 'Authorization: Bearer abbey-release-gate-operator-token' \
    "http://127.0.0.1:${SERVER_PORT}/api/status" >"$WORK_DIR/status.json"
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
assert payload.get("databaseDialect") == "sqlite-file", payload
PY
python3 Scripts/release-container/lifecycle.py create \
    "http://127.0.0.1:${SERVER_PORT}" "$SERVER_CONTAINER" "$WORK_DIR/manager-lifecycle.json"

echo "======== 4/7 restart full server against the same state ========"
docker exec "$SERVER_CONTAINER" /bin/sh -c 'test -w "$HOME/.abbey" && printf persisted > "$HOME/.abbey/release-state-probe"'
docker rm -f "$SERVER_CONTAINER" >/dev/null
run_server
SERVER_PORT="$(published_port "$SERVER_CONTAINER" 8080)"
wait_for_http "$SERVER_CONTAINER" "http://127.0.0.1:${SERVER_PORT}/health" "$WORK_DIR/health-restart.json" "restarted Abbey server"
test -s "$WORK_DIR/server/abbey.sqlite"
docker exec "$SERVER_CONTAINER" /bin/sh -c 'test "$(cat "$HOME/.abbey/release-state-probe")" = persisted'
python3 Scripts/release-container/lifecycle.py restart \
    "http://127.0.0.1:${SERVER_PORT}" "$SERVER_CONTAINER" "$WORK_DIR/manager-lifecycle.json"
docker rm -f "$SERVER_CONTAINER" >/dev/null

echo "======== 5/7 prepare and render packaged Quasar scaffold ========"
docker run --detach --init \
    --name "$PREVIEW_CONTAINER" \
    --publish 127.0.0.1::3100 \
    --volume "$WORK_DIR/preview:/workspace" \
    --entrypoint /bin/sh \
    "$ABBEY_RELEASE_IMAGE" -c '
        set -eu
        cp -R /app/AbbeyBot_AbbeyQuasarKit.resources/next-site/. /workspace/
        cd /workspace
        bun install --frozen-lockfile --ignore-scripts
        test -x node_modules/.bin/next
        exec bun ./node_modules/next/dist/bin/next dev --hostname 0.0.0.0 --port 3100
    ' >/dev/null
PREVIEW_PORT="$(published_port "$PREVIEW_CONTAINER" 3100)"
wait_for_http "$PREVIEW_CONTAINER" "http://127.0.0.1:${PREVIEW_PORT}/" "$WORK_DIR/preview-first.html" "Quasar preview"
grep -Fq "generated yet" "$WORK_DIR/preview-first.html"
docker rm -f "$PREVIEW_CONTAINER" >/dev/null

echo "======== 6/7 restart the prepared Quasar scaffold ========"
docker run --detach --init \
    --name "$PREVIEW_CONTAINER" \
    --publish 127.0.0.1::3100 \
    --volume "$WORK_DIR/preview:/workspace" \
    --entrypoint /bin/sh \
    "$ABBEY_RELEASE_IMAGE" -c '
        set -eu
        cd /workspace
        test -f package.json
        test -x node_modules/.bin/next
        exec bun ./node_modules/next/dist/bin/next dev --hostname 0.0.0.0 --port 3100
    ' >/dev/null
PREVIEW_PORT="$(published_port "$PREVIEW_CONTAINER" 3100)"
wait_for_http "$PREVIEW_CONTAINER" "http://127.0.0.1:${PREVIEW_PORT}/" "$WORK_DIR/preview-restart.html" "restarted Quasar preview"
grep -Fq "generated yet" "$WORK_DIR/preview-restart.html"
docker rm -f "$PREVIEW_CONTAINER" >/dev/null

echo "======== 7/7 validate production Caddy routing and proxy traffic ========"
docker run --rm --entrypoint caddy "$ABBEY_CADDY_RELEASE_IMAGE" list-modules \
    | grep -Fqx 'dns.providers.cloudflare'
docker run --rm \
    --env ABBEY_API_DOMAIN=api.example.test \
    --env ABBEY_QUASAR_PREVIEW_DOMAIN=preview.example.test \
    --env ABBEY_QUASAR_PREVIEW_INTERNAL_TOKEN=abbey-release-gate-internal-token \
    --env ACME_EMAIL=operator@example.test \
    --env CLOUDFLARE_API_TOKEN=cloudflare-release-gate-token \
    --entrypoint caddy \
    "$ABBEY_CADDY_RELEASE_IMAGE" \
    adapt --config /etc/caddy/Caddyfile --adapter caddyfile --pretty --validate \
    >"$WORK_DIR/caddy.json"
for required in \
    '/internal/*' \
    '/internal/quasar/preview/redeem' \
    '{http.request.uri.query}' \
    '/internal/quasar/preview/authorize' \
    'X-Abbey-Preview-Service-Token' \
    'X-Abbey-Preview-Host' \
    'X-Abbey-Preview-URI' \
    'X-Quasar-Upstream'; do
    grep -Fq "$required" "$WORK_DIR/caddy.json"
done
python3 - "$WORK_DIR/caddy.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    json.load(handle)
PY

# Preserve the adapted production routes verbatim. Only listener/TLS settings
# change for this private-network proxy fixture; no public certificates are used.
python3 Scripts/release-container/caddy-http-config.py "$WORK_DIR/caddy.json" "$WORK_DIR/caddy-http.json"
docker run --detach --init --read-only \
    --name "$PROXY_FIXTURE_CONTAINER" --network "$GATE_NETWORK" \
    --network-alias abbey --network-alias preview-backend \
    --volume "$ROOT/Scripts/release-container:/release-fixtures:ro" \
    --entrypoint bun "$ABBEY_RELEASE_IMAGE" /release-fixtures/proxy-fixture.mjs >/dev/null
for _ in $(seq 1 30); do
    if docker exec "$PROXY_FIXTURE_CONTAINER" curl --fail --silent http://127.0.0.1:8080/health >/dev/null; then break; fi
    sleep 1
done
docker exec "$PROXY_FIXTURE_CONTAINER" curl --fail --silent http://127.0.0.1:8080/health >/dev/null
docker run --detach --init --read-only \
    --name "$CADDY_CONTAINER" --network "$GATE_NETWORK" \
    --publish 127.0.0.1::8080 \
    --tmpfs /config --tmpfs /data --tmpfs /tmp \
    --volume "$WORK_DIR/caddy-http.json:/release-caddy.json:ro" \
    --entrypoint caddy "$ABBEY_CADDY_RELEASE_IMAGE" run --config /release-caddy.json >/dev/null
CADDY_PORT="$(published_port "$CADDY_CONTAINER" 8080)"
for _ in $(seq 1 30); do
    if curl --fail --silent --header 'Host: api.example.test' "http://127.0.0.1:${CADDY_PORT}/health" >/dev/null; then break; fi
    sleep 1
done
if ! python3 Scripts/release-container/proxy-check.py "$CADDY_PORT"; then
    docker logs "$CADDY_CONTAINER" >&2 || true
    exit 1
fi
docker rm -f "$CADDY_CONTAINER" "$PROXY_FIXTURE_CONTAINER" >/dev/null

echo "======== real PostgreSQL and release-image restore recovery ========"
ABBEY_RELEASE_IMAGE="$ABBEY_RELEASE_IMAGE" \
ABBEY_CADDY_RELEASE_IMAGE="$ABBEY_CADDY_RELEASE_IMAGE" \
  bash "$ROOT/deploy/production/tests/container-restore.sh"

echo "======== RELEASE CONTAINER GREEN ========"
