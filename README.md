# AbbeyBot

Swift 6.4 dual product on **macOS 27**: **desktop companion** + **headless Discord server**.

| Layer | Tech |
|-------|------|
| Desktop | `AbbeyBot` — macOS 27 SwiftUI + SwiftData |
| Server | `AbbeyServer` — Vapor + Fluent/Postgres + Leaf |
| Core | `AbbeyCore` — brain, personas, inference, DiscordBM |
| Discord | DiscordBM gateway + REST (Voice deferred) |

## Run desktop

```bash
bash Scripts/run.sh
# or:
unset TOOLCHAINS
cd ~/Desktop/AbbeyBot
/usr/bin/xcrun --toolchain default swift run AbbeyBot --build-path "${TMPDIR}/AbbeyBot.build"
```

## Run server

```bash
cp .env.example .env   # fill DISCORD_BOT_TOKEN, etc.
docker compose up -d db   # optional if using Postgres
bash Scripts/run-server.sh
```

Or full stack: `docker compose up --build`.

## Verify

```bash
bash Scripts/run-smoke.sh
bash Scripts/run-server-smoke.sh   # Postgres via compose, or sqlite file if Docker missing
bash Scripts/verify-all.sh         # both
```

## Discord

1. Create a bot; enable **Message Content** intent.
2. Desktop: Discord sidebar → token (Keychain) → Connect → Register slash commands.
3. Server: set `DISCORD_BOT_TOKEN` / `DISCORD_DEV_GUILD_ID` in `.env`; gateway starts on boot.

Slash commands: `ask`, `rep`, `remember`, `forget`, `context`, `persona`.

## Layout

```
Sources/AbbeyCore/      # shared library (no SwiftData)
Sources/AbbeyBotApp/    # @main SwiftUI + SwiftData models
Sources/AbbeyServer/    # Vapor executable + Fluent models
Scripts/                # run-smoke.sh, run-server-smoke.sh
deploy/abbeybot.service
Dockerfile / docker-compose.yml
```

## API (server)

- `GET /health` — liveness + Discord state
- `GET /api/metrics` — session counters
- `GET /api/status` — dialect + table counts + session metrics (JSON)
- `POST /api/ingest` — headless ingest (`content`, `channelId`, `guildId`, `authorId`, optional `discordMessageId`); when `ABBEY_API_TOKEN` is set, require `Authorization: Bearer …` or `X-Abbey-Token`
- `GET /api/users` / `GET /api/channels` — Fluent rows (`?limit=`)
- `GET /api/messages` / `GET /api/reputation` / `GET /api/interactions` / `GET /api/equity` — recent rows (`?limit=`)
- `GET /` — Leaf status (dialect + table counts)

## Status

Core shared helpers shipped (`IngestScorer`, `ReputationMath`, `DiscordCopy`, async Vapor lifecycle). Still deferred: React SPA, Voice, Desktop↔Postgres sync.
