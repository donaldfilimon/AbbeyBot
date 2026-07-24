# AGENTS.md — AbbeyBot

Unified Abbey bot at `~/Desktop/AbbeyBot` — **two products** in one package. **macOS 27**.

## Stack

| Product | Target | Store | UI |
|---------|--------|-------|-----|
| Desktop | `AbbeyBot` (`AbbeyBotApp`) | SwiftData | SwiftUI |
| Server | `AbbeyServer` | Fluent + Postgres (SQLite smoke fallback) | Leaf status + `/api/*` |

Shared: `AbbeyCore` (personas, inference, DiscordBM bridge, DQN). Swift 6.4 language mode; Xcode toolchain only (`xcrun --toolchain default` — swiftly DEVELOPMENT-SNAPSHOT breaks SwiftData macros).

## Verify

```bash
unset TOOLCHAINS
bash Scripts/run-smoke.sh          # desktop build/test/launch
bash Scripts/run-server-smoke.sh   # AbbeyServer + compose Postgres or sqlite file + GET /health
```

Launch wrappers (Xcode toolchain):

```bash
bash Scripts/run.sh          # desktop
bash Scripts/run-server.sh   # server (loads .env if present)
```

Build paths use `${TMPDIR}/AbbeyBot*.build` to avoid Desktop/iCloud xattr codesign failures.

## Discord live path (desktop)

1. Developer Portal bot + Message Content intent
2. Discord tab → paste token (Keychain) → Connect
3. Optional: Dev guild ID → Register slash commands
4. Settings operating mode `liveDiscord` + auto-connect optional

## Server ops

Env: see `.env.example` (`DISCORD_BOT_TOKEN`, `DISCORD_DEV_GUILD_ID`, `DATABASE_URL`).

`DATABASE_URL`: `postgres://…` / `postgresql://…`, `sqlite://memory` / `sqlite::memory:`, or `sqlite:///path`. Boot logs `Database dialect: postgres|sqlite-memory|sqlite-file`.

```bash
docker compose up -d db          # Postgres 16
/usr/bin/xcrun --toolchain default swift run AbbeyServer serve --hostname 0.0.0.0 --port 8080
# or: docker compose up --build
# without Docker: DATABASE_URL=sqlite://${TMPDIR}/abbey.sqlite …
```

Routes: `GET /health`, `GET /api/metrics`, `GET /api/users`, `GET /api/channels`, `GET /` (Leaf).

Deploy: `Dockerfile` (`swift:6.0-bookworm`, copies `AbbeyServer_*.resources`), `docker-compose.yml`, `deploy/abbeybot.service`. Presence activity: bridge default `"AbbeyBot"`; server passes `"AbbeyServer"`.

Server smoke (`Scripts/run-server-smoke.sh`) uses compose Postgres when Docker is up; otherwise `sqlite://` file under `$TMPDIR` (`${TMPDIR}/AbbeyBot.server.build`).

## Phase 2

Shipped: Vapor HTTP, Fluent/Postgres, Leaf status, Docker/systemd, macOS 27 desktop APIs. Not in this phase: React SPA, Voice, SwiftData↔Postgres sync.
