# AbbeyBot

Swift 6.4 dual product on **macOS 27**: **desktop companion** + **headless Discord server**.

| Layer | Tech |
|-------|------|
| Desktop | `AbbeyBot` — macOS 27 SwiftUI + SwiftData |
| Server | `AbbeyServer` — Vapor + Fluent/Postgres + Leaf + `/dashboard` SPA |
| Shared engine | `AbbeyServerKit` — Fluent-backed `BotRuntime` used by server + CLI |
| CLI | `abbey` — terminal chat sharing the same brain, local SQLite |
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

## Run abbey CLI

```bash
bash Scripts/run-abbey.sh
# or:
unset TOOLCHAINS
cd ~/Desktop/AbbeyBot
/usr/bin/xcrun --toolchain default swift run --build-path "${TMPDIR}/AbbeyBot.cli.build" abbey
```

Local SQLite state lives at `~/.abbey/abbey.sqlite` (directory auto-created); override with `DATABASE_URL` same as the server (`postgres://…`, `sqlite://memory`, `sqlite://<path>`). Set `DISCORD_BOT_TOKEN` (and optional `DISCORD_DEV_GUILD_ID`) to connect live to Discord, otherwise it runs local-only with a warning logged.

Commands:

- `/help` — list commands
- `/clear` — start a fresh conversation thread (non-destructive, keeps history)
- `/model` — show current inference mode; `/model <mode>` — switch (`deterministicFloor`, `onDevice`, `remoteCompatible`)
- `/exit` — quit (Ctrl-D / EOF also exits cleanly)

## Verify

```bash
bash Scripts/run-smoke.sh
bash Scripts/run-server-smoke.sh   # Postgres via compose, or sqlite file if Docker missing
bash Scripts/verify-all.sh         # both
```

CI (`.github/workflows/ci.yml`) runs `AbbeyCore`/`AbbeyServerKit`/`AbbeyServer`/`AbbeyCLI` build + tests on Linux on every push/PR. Desktop (`AbbeyBotApp`) has no hosted CI yet — it needs a macOS 27 host, which GitHub-hosted runners don't provide; that job is present but disabled pending a self-hosted runner.

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
Sources/AbbeyServerKit/ # shared Fluent-backed engine (BotRuntime, Models, Persistence) used by AbbeyServer + abbey CLI
Sources/AbbeyCLI/       # abbey terminal chat executable
Scripts/                # run-smoke.sh, run-server-smoke.sh
deploy/abbeybot.service
Dockerfile / docker-compose.yml
```

## API (server)

- `GET /health` — liveness + Discord state
- `GET /dashboard` — React SPA (build with `bun run build` / `npm run build` in `web/`)
- `GET /api/metrics` — session counters
- `GET /api/status` — dialect + table counts + session metrics (JSON)
- `POST /api/ingest` — headless ingest (`content`, `channelId`, `guildId`, `authorId`, optional `discordMessageId`); when `ABBEY_API_TOKEN` is set, require `Authorization: Bearer …` or `X-Abbey-Token`
- State (desktop sync): `GET /api/state/user`, `GET /api/state/channel`, `POST /api/state/remember`, `POST /api/state/forget`
- `GET /api/users` / `GET /api/channels` — Fluent rows (`?limit=`)
- `GET /api/messages` / `GET /api/reputation` / `GET /api/interactions` / `GET /api/equity` — recent rows (`?limit=`)
- `GET /` — Leaf status (dialect + table counts)

Desktop optional sync: Settings / `ABBEY_SYNC_SERVER_URL` + `ABBEY_SYNC_API_TOKEN` best-effort mirrors ingest/remember/forget to AbbeyServer (failures never block local SwiftData writes).

## Status

Shipped: shared core helpers (`IngestScorer`, `ReputationMath`, `DiscordCopy`), AbbeyServerKit + CLI, `/dashboard` SPA, one-way desktop→server HTTP sync. Still deferred: Discord Voice; full bidirectional SwiftData↔Postgres sync.
