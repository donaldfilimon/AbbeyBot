# AbbeyBot

> **Intelligence Without Limits** — Abbey desktop + Discord companion (Swift).  
> Local-first assistance with memory, personas, and explicit safety boundaries.  
> Discord voice and live services need operator config; see claims in `docs/`.


Swift 6.4 dual product on **macOS 27**: **desktop companion** + **headless Discord server**.

| Layer | Tech |
|-------|------|
| Desktop | `AbbeyBot` — macOS 27 SwiftUI + SwiftData |
| Server | `AbbeyServer` — Vapor + Fluent/Postgres + Leaf + `/dashboard` SPA |
| Shared engine | `AbbeyServerKit` — Fluent-backed `BotRuntime` used by server + CLI |
| CLI | `abbey` — terminal chat sharing the same brain, local SQLite |
| Core | `AbbeyCore` — brain, personas, inference, DiscordBM |
| Quasar | `AbbeyQuasarKit` — bounded site scaffolding, proposal-gated mutation, preview, archive/restore |
| Discord | DiscordBM gateway + REST; voice presence is verified, while consent-gated audio paths remain unverified in a live DAVE call |

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

Local SQLite state lives at `~/.abbey/abbey.sqlite` (directory auto-created; `ABBEY_DATA_DIR` relocates the whole `~/.abbey` data directory, including the DQN journal/checkpoint, WDBX and rollback snapshots); override with `DATABASE_URL` same as the server (`postgres://…`, `sqlite://memory`, `sqlite://<path>`). Set `DISCORD_BOT_TOKEN` (and optional `DISCORD_DEV_GUILD_ID`) to connect live to Discord, otherwise it runs local-only with a warning logged.

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
bash Scripts/check-static-security.sh
bash Scripts/run-web-smoke.sh
bash Scripts/run-smoke.sh          # all five Swift test bundles + desktop launch
bash Scripts/run-server-smoke.sh   # Postgres via compose, or sqlite file if Docker missing
bash Scripts/run-cli-smoke.sh
bash Scripts/verify-all.sh         # complete local release gate
```

CI (`.github/workflows/abbey-ci.yml`) runs the static/security check, lints/tests/builds the dashboard SPA, then builds product `AbbeyBot` with `ABBEY_PACKAGE_ROLE=server` and runs `AbbeyCoreTests`/`AbbeyQuasarKitTests`/`AbbeyCLITests`/`AbbeyServerKitTests`/`AbbeyServerTests` on Linux for main and review-branch pushes and pull requests into main. The workflow has no desktop job; desktop verification uses the local Xcode gate.

Hosted Linux CI is operational; the latest documented PR runs passed. Treat
those runs as evidence for their exact commits, not as a substitute for the
local gate or for macOS desktop and live-service validation.

The selected deployment candidate is the observed canonical `main` commit
`a9b6c1712178b664d217eab03b55e0c2475f66d3`. On that exact commit the ordinary
gate passed 874 Swift tests and 17 web tests, including signed desktop and
SQLite server/CLI smokes; the native gate passed 102 tests in 9 suites in both
debug and release after a fresh pinned bootstrap. Hosted
[CI run 34217866364](https://github.com/donaldfilimon/AbbeyBot/actions/runs/34217866364)
and [release run 34217866428](https://github.com/donaldfilimon/AbbeyBot/actions/runs/34217866428)
also succeeded on that SHA. This is repository and publication evidence, not
production deployment or live-service acceptance.

Current completion evidence and unresolved deployment/media requirements are in
[the September 16 integration ledger](docs/verification/product-integration-2026-09-16.md).
It records commit-specific local and hosted results; production rollout and live
Quasar, Twitch and Discord acceptance remain open.

## Discord

1. Create a bot; enable **Message Content** intent.
2. Desktop: Discord sidebar → token (Keychain) → Connect → Register slash commands.
3. Server: set `DISCORD_BOT_TOKEN` / `DISCORD_DEV_GUILD_ID` in `.env`; gateway starts on boot.

Slash commands:

- Inference: `/ask`, `/explain`, `/summarize`, `/model`
- Memory and social brain: `/rep`, `/facts`, `/remember`, `/forget`, `/context`
- Operations: `/status`, `/ping`, `/help`, `/industry`, `/persona`
- Safety-scoped modules: `/mod` provides Abi moderation advice only; `/equity` is a synthetic factor screen, not market data or financial advice
- Voice: `/voice join|leave` controls gateway presence. Local capture, protected
  send, receive, and playback paths are composed behind explicit operator gates,
  but the advertised DAVE version remains `0` until a participant-consented live
  Discord join/speak/hear/reconnect/leave run succeeds.

Re-register slash commands after upgrading so Discord receives the expanded registry.

## Knowledge and Quasar workspaces

The desktop now includes a signed, byte-exact knowledge snapshot and a Quasar
workspace. The snapshot is generated by `Scripts/refresh-knowledge-snapshot.swift`
and its signature/manifest contract is checked by
`Scripts/check-knowledge-snapshot.sh`; refreshing it is an explicit source
operation, not a background network crawl.

Quasar stores bounded local site workspaces under its configured home, uses a
single-writer registry, previews mutation plans before approval, and retains
verified rollback/archive receipts. Its server API requires a dedicated token
and an allowlisted origin. Those source and local-test guarantees do not prove
a public deployment, a live model-backed generation, or Discord authorization
for a real guild.

## Layout

```
Sources/AbbeyCore/      # shared library (no SwiftData)
Sources/AbbeyQuasarKit/ # bounded site generation/mutation/preview/archive library
Sources/AbbeyEntry/     # sole @main → desktop | serve | quasar serve | cli
Sources/AbbeyBotApp/    # SwiftUI + SwiftData desktop (via bare `swift run`)
Sources/AbbeyServer/    # Vapor HTTP + Discord (via `swift run -- serve`)
Sources/AbbeyServerKit/ # shared Fluent-backed engine (BotRuntime, Models, Persistence)
Sources/AbbeyCLI/       # abbey terminal REPL (via `swift run -- cli`)
Sources/AbbeyMediaMacOS/  # AVFoundation capture/playback; dropped by ABBEY_PACKAGE_ROLE=server
Sources/AbbeyMediaNative/ # DAVE/Opus/libsodium paths; added only by ABBEY_NATIVE_MEDIA=1
Sources/{CLibDave,COpus,CSodium}/  # C shims for the native-media opt-in
Contracts/Abbey/        # vendored corpus, also packaged by AbbeyCore
web/                    # dashboard SPA (bun/Biome/Vitest/Vite → AbbeyServer Resources/Public)
functions/              # optional Browserbase Bun package, outside CI and verify-all
Scripts/                # run.sh, run-smoke.sh, run-server-smoke.sh
deploy/abbeybot.service
Dockerfile / docker-compose.yml
deploy/production/      # digest-pinned Compose, Caddy, backup/deploy/restore
```

The provider-neutral production runbook is in
[`deploy/production/README.md`](deploy/production/README.md). Release images
are built on GitHub Actions from `main`; the server host consumes the recorded
SHA-256 image references and does not build Swift, Bun, or Caddy locally.
For the selected `a9b6c17` candidate, CI published
`ghcr.io/donaldfilimon/abbeybot@sha256:6a7d9ea4b8a0b428c063ef87664d121ac4926f5bca4602a4048fbb1554722440`
and
`ghcr.io/donaldfilimon/abbeybot-caddy@sha256:31698e48b2971c0e3332508f05bf3c59f28530077305b6cc81d012c8430ca8b1`.
They have not been registry-inspected with package-read access or deployed.

## API (server)

- `GET /health` — liveness + Discord state
- `GET /dashboard` — React SPA (build with `bun run build` / `npm run build` in `web/`); tabs include Interactions + Equity (disclaimer); load-more capped at 500
- `GET /api/metrics` — session counters
- `GET /api/status` — dialect + table counts + session metrics (JSON)
- `GET /api/knowledge/search` — operator-authenticated search over the bundled signed snapshot, with citations
- `POST /api/ingest` — headless ingest (`content`, `channelId`, `guildId`, `authorId`, optional `discordMessageId`); when `ABBEY_API_TOKEN` is set, require `Authorization: Bearer …` or `X-Abbey-Token` (same gate on list GETs and mutating `/api/state` POSTs)
- State (desktop sync): `GET /api/state/user`, `GET /api/state/channel`, `POST /api/state/remember`, `POST /api/state/forget`, `POST /api/state/tombstone/{user,channel,message,reputation,interaction,equity}`, `POST /api/state/sync-status`
- `GET /api/users` / `GET /api/channels` — Fluent rows (`?limit=`)
- `GET /api/messages` / `GET /api/reputation` / `GET /api/interactions` / `GET /api/equity` — recent rows (`?limit=`, max 500)
- `GET /` — Leaf status; Operator UI + JSON API nav; Dashboard SPA link when `Public/index.html` exists, else build hint

Desktop: sidebar includes **Interactions**; Users uses `HSplitView`; Settings uses human titles and shows Server sync push/pull last success/failure. Optional sync (`ABBEY_SYNC_SERVER_URL` / `ABBEY_SYNC_API_TOKEN`) — push mirrors ingest/remember/forget; pull on launch + “Pull now” covers users/channels/messages/reputation/interactions/equity. Plain HTTP is accepted only for exact loopback hosts; remote sync requires HTTPS. Per-entity compound `(changedAt, stable ID)` cursors drain 500-row pages without losing equal-timestamp overflow; users/channels use LWW by `updatedAt`, equity by `generatedAt`, and all six entity types carry `deletedAt` tombstones that pull applies as local hard-deletes. Failures never advance cursors or block local SwiftData writes.

The `abbey` CLI also syncs with the same server: `/sync pull` (own persisted per-entity compound cursor set, automatic legacy timestamp migration, same LWW/tombstone rules) and `/sync push` (messages + memory facts only — see Commands above).

## Status

Verified shipped runtime: shared core helpers (`IngestScorer`,
`ReputationMath`, `DiscordCopy`), AbbeyServerKit + CLI, `/dashboard` SPA,
desktop Interactions + sync feedback, Discord voice presence, desktop↔server
push + lossless compound-cursor pull with all-six-entity tombstones, CLI↔server
sync (`/sync pull` + `/sync push`), and Twitch EventSub's locally tested HMAC,
replay-dedup, chat, stream-lifecycle, follow, subscribe, and cheer paths.
Implemented but not live-verified or claimed as shipped: consent-gated Discord
audio send/receive/playback, the native VideoToolbox H.264/RFC 6184 video path,
Quasar provider-backed generation and live Discord approval, and Twitch service
integration. Local preview text continues to state that video frames are not
transmitted until the live media qualification boundary is actually cleared.
Still deferred:
true CRDT multi-writer merge (LWW + tombstones remains the sync story).

Current source evidence was refreshed on 2026-09-08 at exact merged commit
`a9b6c1712178b664d217eab03b55e0c2475f66d3`: `verify-all` completed with
`VERIFY-ALL GREEN` (874 ordinary Swift tests and 17 web tests), and the native
gate completed with `NATIVE_MEDIA_SMOKE_GREEN` (102 tests in 9 suites in both
debug and release). Local composition remains separate from a
participant-consented live Discord call; the selected video wire codec is still
unknown until an allowed metadata-only protocol observation occurs.

Historical 2026-08-27 evidence remains relevant: debug and release desktop
builds completed, the focused `AbbeyCoreTests` rerun passed 449 tests after one
full-suite run exposed a non-reproducible test-target failure, and `verify-all`
subsequently completed with `VERIFY-ALL GREEN`.

## Related implementation

The separate Rust `abbey-bot` repository is a serenity/poise Discord
operational bot. It shares no runtime code or persistence with this Swift
product. Do not combine their repositories or acceptance claims.
Cross-language contract compatibility is reviewed through exact vendored
corpus bytes and native consumer tests, not by importing one bot into the
other.
