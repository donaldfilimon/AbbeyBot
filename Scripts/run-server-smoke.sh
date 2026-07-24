#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset TOOLCHAINS || true
BUILD_PATH="${TMPDIR:-/tmp}/AbbeyBot.server.build"
SWIFT=(/usr/bin/xcrun --toolchain default swift)
COMPOSE=(docker compose)

echo "======== 1/7 build AbbeyServer ========"
"${SWIFT[@]}" build --product AbbeyServer --build-path "$BUILD_PATH"

BIN="$BUILD_PATH/debug/AbbeyServer"
if [[ ! -x "$BIN" ]]; then
  BIN="$(find "$BUILD_PATH" -name AbbeyServer -type f -perm +111 | head -1)"
fi
test -x "$BIN"

USE_SQLITE=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "======== 2/7 postgres (docker compose) ========"
  "${COMPOSE[@]}" up -d db
  echo "Waiting for Postgres..."
  for _ in $(seq 1 30); do
    if "${COMPOSE[@]}" exec -T db pg_isready -U abbey -d abbeybot >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  "${COMPOSE[@]}" exec -T db pg_isready -U abbey -d abbeybot
  export DATABASE_URL="${DATABASE_URL:-postgres://abbey:abbey@127.0.0.1:5432/abbeybot}"
else
  echo "======== 2/7 postgres unavailable — sqlite file smoke ========"
  USE_SQLITE=1
  SQLITE_PATH="${TMPDIR:-/tmp}/abbeyserver-smoke.sqlite"
  rm -f "$SQLITE_PATH"
  export DATABASE_URL="sqlite://${SQLITE_PATH}"
fi

export DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
export HTTP_HOSTNAME=127.0.0.1
export HTTP_PORT=18080

echo "======== 3/7 boot server (db=$DATABASE_URL) ========"
"$BIN" serve --hostname "$HTTP_HOSTNAME" --port "$HTTP_PORT" >/tmp/abbeyserver-smoke.log 2>&1 &
PID=$!
cleanup() {
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}
trap cleanup EXIT

ok=0
for _ in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:${HTTP_PORT}/health" >/tmp/abbeyserver-health.json; then
    ok=1
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "Server exited early:"
    cat /tmp/abbeyserver-smoke.log || true
    exit 1
  fi
  sleep 0.5
done

if [[ "$ok" != "1" ]]; then
  echo "HEALTH_TIMEOUT"
  cat /tmp/abbeyserver-smoke.log || true
  exit 1
fi

echo "======== 4/7 assert /health ========"
cat /tmp/abbeyserver-health.json
python3 -c 'import json; d=json.load(open("/tmp/abbeyserver-health.json")); assert d.get("status")=="ok", d'

echo "======== 5/7 assert /dashboard ========"
DASHBOARD_STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/dashboard")"
if [[ "$DASHBOARD_STATUS" == "200" ]]; then
  echo "dashboard_ok status=$DASHBOARD_STATUS"
elif [[ "$DASHBOARD_STATUS" == "404" ]]; then
  echo "dashboard_skipped (not built — run 'bun run build' in web/ first; this is not a failure)"
else
  echo "dashboard_FAILED status=$DASHBOARD_STATUS"
  exit 1
fi

echo "======== 6/7 assert /api/status + ingest ========"
curl -sf "http://127.0.0.1:${HTTP_PORT}/api/status" >/tmp/abbeyserver-status.json
python3 -c 'import json; d=json.load(open("/tmp/abbeyserver-status.json")); assert "databaseDialect" in d and d.get("messages", -1) >= 0, d'
echo "status_ok dialect=$(python3 -c 'import json; print(json.load(open("/tmp/abbeyserver-status.json")).get("databaseDialect"))')"
curl -sf -X POST "http://127.0.0.1:${HTTP_PORT}/api/ingest" \
  -H 'Content-Type: application/json' \
  -d '{"content":"hello abbey smoke","channelId":"smoke","guildId":"smoke","authorId":"smoke-user"}' \
  >/tmp/abbeyserver-ingest.json
python3 -c 'import json; d=json.load(open("/tmp/abbeyserver-ingest.json")); assert d.get("ok") is True and d.get("discordMessageId"), d'
echo "ingest_ok id=$(python3 -c 'import json; print(json.load(open("/tmp/abbeyserver-ingest.json")).get("discordMessageId"))')"

echo "======== 7/7 assert list APIs after ingest ========"
curl -sf "http://127.0.0.1:${HTTP_PORT}/api/messages?limit=10" >/tmp/abbeyserver-messages.json
python3 -c 'import json; d=json.load(open("/tmp/abbeyserver-messages.json")); assert isinstance(d, list) and len(d) >= 1, d'
echo "messages_ok count=$(python3 -c 'import json; print(len(json.load(open("/tmp/abbeyserver-messages.json"))))')"
# Ingest bumps channel, creates UserMemory + ReputationEvent, and logs InteractionLog.
for path in users channels reputation interactions; do
  curl -sf "http://127.0.0.1:${HTTP_PORT}/api/${path}?limit=10" >"/tmp/abbeyserver-${path}.json"
  python3 -c "import json; d=json.load(open('/tmp/abbeyserver-${path}.json')); assert isinstance(d, list) and len(d) >= 1, d"
  echo "${path}_ok count=$(python3 -c "import json; print(len(json.load(open('/tmp/abbeyserver-${path}.json'))))")"
done
curl -sf "http://127.0.0.1:${HTTP_PORT}/api/equity?limit=10" >/tmp/abbeyserver-equity.json
python3 -c 'import json; d=json.load(open("/tmp/abbeyserver-equity.json")); assert isinstance(d, list), d'
echo "equity_ok count=$(python3 -c 'import json; print(len(json.load(open("/tmp/abbeyserver-equity.json"))))')"
curl -sf "http://127.0.0.1:${HTTP_PORT}/api/metrics" >/tmp/abbeyserver-metrics.json
python3 -c 'import json; d=json.load(open("/tmp/abbeyserver-metrics.json")); assert "messagesIngested" in d and d.get("messagesIngested", -1) >= 0, d'
echo "metrics_ok messagesIngested=$(python3 -c 'import json; print(json.load(open("/tmp/abbeyserver-metrics.json")).get("messagesIngested"))')"

if [[ "$USE_SQLITE" == "1" ]]; then
  echo "(note: smoke used sqlite file because Docker/Postgres was unavailable)"
fi

echo
echo "======== SERVER SMOKE GREEN ========"
