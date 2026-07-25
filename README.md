# AbbeyBot

Swift 6.4 dual product on **macOS 27**: **desktop companion** + **headless Discord server**.

| Layer | Tech |
|-------|------|
| Desktop | `AbbeyBot` — macOS 27 SwiftUI + SwiftData |
| Server | `AbbeyServer` — Vapor + Fluent/Postgres + Leaf + `/dashboard` SPA |
| Shared engine | `AbbeyServerKit` — Fluent-backed `BotRuntime` used by server + CLI |
| CLI | `abbey` — terminal chat sharing the same brain, local SQLite |
| Core | `AbbeyCore` — brain, personas, inference, DiscordBM |
| Discord | DiscordBM gateway + REST (voice presence join/leave; audio deferred) |

## Run

One executable product (`AbbeyBot`). Bare `swift run` launches the **desktop** app (macOS / Xcode).

```bash
unset TOOLCHAINS
swift run                         # desktop (Xcode toolchain; not swiftly)
swift run AbbeyBot serve          # AbbeyServer
swift run AbbeyBot cli            # abbey REPL
# or wrappers:
bash Scripts/run.sh
bash Scripts/run-server.sh
bash Scripts/run-abbey.sh
```

Swiftly / DEVELOPMENT-SNAPSHOT **cannot** build the desktop target. For server/CLI under swiftly:

```bash
ABBEY_SWIFT=swiftly bash Scripts/run-server.sh   # sets ABBEY_PACKAGE_ROLE=server
ABBEY_SWIFT=swiftly bash Scripts/run-abbey.sh
```

Unset `DATABASE_URL` falls back to sqlite under `$TMPDIR` when Postgres is down. Full stack: `docker compose up --build`.

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

CI (`.github/workflows/abbey-ci.yml`) builds the dashboard SPA (`bun test` + `bun run build`), then builds product `AbbeyBot` with `ABBEY_PACKAGE_ROLE=server` and runs `AbbeyCoreTests`/`AbbeyCLITests`/`AbbeyServerKitTests` on Linux on every push/PR. Desktop (`AbbeyBotApp`) has no hosted CI yet — it needs a macOS 27 host, which GitHub-hosted runners don't provide; that job is present but disabled pending a self-hosted runner.

**GitHub Actions billing:** this private repo's hosted workflows currently **`startup_failure` (0 jobs)** until Actions spending/quota is enabled under **Settings → Billing → Actions**. Use **`bash Scripts/verify-all.sh` locally** as the gate until then; after unblock, re-run **Abbey CI** (`abbey-ci`). CI is **not** green on GitHub today.

## Discord

1. Create a bot; enable **Message Content** intent.
2. Desktop: Discord sidebar → token (Keychain) → Connect → Register slash commands.
3. Server: set `DISCORD_BOT_TOKEN` / `DISCORD_DEV_GUILD_ID` in `.env`; gateway starts on boot.

Slash commands: `ask`, `rep`, `remember`, `forget`, `context`, `persona`.

## Layout

```
Sources/AbbeyCore/      # shared library (no SwiftData)
Sources/AbbeyEntry/     # sole @main → desktop | serve | cli
Sources/AbbeyBotApp/    # SwiftUI + SwiftData desktop (via bare `swift run`)
Sources/AbbeyServer/    # Vapor HTTP + Discord (via `swift run -- serve`)
Sources/AbbeyServerKit/ # shared Fluent-backed engine (BotRuntime, Models, Persistence)
Sources/AbbeyCLI/       # abbey terminal REPL (via `swift run -- cli`)
Scripts/                # run.sh, run-smoke.sh, run-server-smoke.sh
deploy/abbeybot.service
Dockerfile / docker-compose.yml
```

## API (server)

- `GET /health` — liveness + Discord state
- `GET /dashboard` — React SPA (build with `bun run build` / `npm run build` in `web/`); tabs include Interactions + Equity (disclaimer); load-more capped at 500
- `GET /api/metrics` — session counters
- `GET /api/status` — dialect + table counts + session metrics (JSON)
- `POST /api/ingest` — headless ingest (`content`, `channelId`, `guildId`, `authorId`, optional `discordMessageId`); when `ABBEY_API_TOKEN` is set, require `Authorization: Bearer …` or `X-Abbey-Token` (same gate on list GETs and mutating `/api/state` POSTs)
- State (desktop sync): `GET /api/state/user`, `GET /api/state/channel`, `POST /api/state/remember`, `POST /api/state/forget`
- `GET /api/users` / `GET /api/channels` — Fluent rows (`?limit=`)
- `GET /api/messages` / `GET /api/reputation` / `GET /api/interactions` / `GET /api/equity` — recent rows (`?limit=`, max 500)
- `GET /` — Leaf status; Operator UI + JSON API nav; Dashboard SPA link when `Public/index.html` exists, else build hint

Desktop: sidebar includes **Interactions**; Users uses `HSplitView`; Settings uses human titles and shows Server sync push/pull last success/failure. Optional sync (`ABBEY_SYNC_SERVER_URL` / `ABBEY_SYNC_API_TOKEN`) — push mirrors ingest/remember/forget; pull on launch + “Pull now” (users/channels/messages **and** reputation/interactions/equity; last-write-wins by `updatedAt` for users/channels and by `generatedAt` for equity; messages/reputation/interactions insert-if-missing; limit 500). Failures never block local SwiftData writes.

## Status

Shipped: shared core helpers (`IngestScorer`, `ReputationMath`, `DiscordCopy`), AbbeyServerKit + CLI, `/dashboard` SPA (Interactions tab, equity disclaimer, teal ops theme), desktop Interactions + sync feedback, voice **presence** (`/voice join|leave`), desktop→server push + pull-on-launch/manual with persisted `?since=` cursors (users/channels/messages/reputation/interactions/equity). Still deferred: Discord Voice **audio** (Opus/UDP); CRDT merge / CLI↔desktop sync.
