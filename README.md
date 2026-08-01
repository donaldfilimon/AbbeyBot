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
unset TOOLCHAINS                  # required if your shell exports TOOLCHAINS=swift
bash Scripts/run.sh               # desktop (preferred — Xcode + safe build path)
bash Scripts/swift-run.sh         # same, raw SPM-style args (serve|cli|help)
bash Scripts/run-server.sh        # AbbeyServer
bash Scripts/run-abbey.sh         # abbey REPL
# or after unset TOOLCHAINS:
# swift run --build-path "${TMPDIR}/AbbeyBot.build"
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
- `/validate <src>` — run generated code through the static `CodeProposalValidator` reject-list (not a sandbox)
- `/sync` — read-only: prints this DB's desktop-reported sync status row, if any
- `/sync pull` — fetch from `ABBEY_SYNC_SERVER_URL` with a persisted `?since=` cursor, apply via the same last-write-wins/tombstone rules as desktop
- `/sync push` — push local messages + memory facts to the server (reputation/interactions/equity have no CLI write surface — they're server-derived)
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

Slash commands:

- Inference: `/ask`, `/explain`, `/summarize`, `/model`
- Memory and social brain: `/rep`, `/facts`, `/remember`, `/forget`, `/context`
- Operations: `/status`, `/ping`, `/help`, `/industry`, `/persona`
- Safety-scoped modules: `/mod` provides Abi moderation advice only; `/equity` is a synthetic factor screen, not market data or financial advice
- Voice: `/voice join|leave` updates muted/deafened gateway presence only; no audio capture or playback

Re-register slash commands after upgrading so Discord receives the expanded registry.

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
- State (desktop sync): `GET /api/state/user`, `GET /api/state/channel`, `POST /api/state/remember`, `POST /api/state/forget`, `POST /api/state/tombstone/{user,channel,message,reputation,interaction,equity}`, `POST /api/state/sync-status`
- `GET /api/users` / `GET /api/channels` — Fluent rows (`?limit=`)
- `GET /api/messages` / `GET /api/reputation` / `GET /api/interactions` / `GET /api/equity` — recent rows (`?limit=`, max 500)
- `GET /` — Leaf status; Operator UI + JSON API nav; Dashboard SPA link when `Public/index.html` exists, else build hint

Desktop: sidebar includes **Interactions**; Users uses `HSplitView`; Settings uses human titles and shows Server sync push/pull last success/failure. Optional sync (`ABBEY_SYNC_SERVER_URL` / `ABBEY_SYNC_API_TOKEN`) — push mirrors ingest/remember/forget; pull on launch + “Pull now” covers users/channels/messages/reputation/interactions/equity. Per-entity compound `(changedAt, stable ID)` cursors drain 500-row pages without losing equal-timestamp overflow; users/channels use LWW by `updatedAt`, equity by `generatedAt`, and all six entity types carry `deletedAt` tombstones that pull applies as local hard-deletes. Failures never advance cursors or block local SwiftData writes.

The `abbey` CLI also syncs with the same server: `/sync pull` (own persisted per-entity compound cursor set, automatic legacy timestamp migration, same LWW/tombstone rules) and `/sync push` (messages + memory facts only — see Commands above).

## Status

Shipped: shared core helpers (`IngestScorer`, `ReputationMath`, `DiscordCopy`), AbbeyServerKit + CLI, `/dashboard` SPA, desktop Interactions + sync feedback, voice **presence** (`/voice join|leave`), desktop↔server push + lossless compound-cursor pull with all-six-entity tombstones, CLI↔server sync (`/sync pull` + `/sync push`), and Twitch EventSub (HMAC verify, replay dedup, chat + stream-lifecycle handling, env-gated auto-subscribe — unverified against live Twitch). Still deferred: Discord Voice **audio** (Opus/UDP); true CRDT multi-writer merge (LWW + tombstones is the sync story instead).
