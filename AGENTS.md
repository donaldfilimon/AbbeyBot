# AGENTS.md — AbbeyBot

Unified Abbey bot at `~/Desktop/AbbeyBot` — **two products** in one package. **macOS 27**.

## Stack

| Product | Target | Store | UI |
|---------|--------|-------|-----|
| Desktop | `AbbeyBot` (`AbbeyBotApp`) | SwiftData | SwiftUI |
| Server | `AbbeyServer` | Fluent + Postgres (SQLite smoke fallback) | Leaf status + `/api/*` + `/dashboard` SPA |
| CLI | `abbey` (`AbbeyCLI`) | SQLite (local, `~/.abbey/`) | Terminal REPL |

Shared: `AbbeyCore` (personas, inference, DiscordBM bridge, DQN) and `AbbeyServerKit` (Fluent-backed engine used by `AbbeyServer` + `abbey`). Swift 6.4 language mode; Xcode toolchain only (`xcrun --toolchain default` — swiftly DEVELOPMENT-SNAPSHOT breaks SwiftData macros).

## Verify

```bash
unset TOOLCHAINS
bash Scripts/run-smoke.sh          # desktop build/test/launch
bash Scripts/run-server-smoke.sh   # AbbeyServer + compose Postgres or sqlite file + GET /health
bash Scripts/verify-all.sh         # both gates
```

Launch wrappers (Xcode toolchain):

```bash
bash Scripts/run.sh          # desktop
bash Scripts/run-server.sh   # server (loads .env if present)
bash Scripts/run-abbey.sh    # abbey CLI (loads .env if present)
```

Build paths use `${TMPDIR}/AbbeyBot*.build` to avoid Desktop/iCloud xattr codesign failures.

CI: `.github/workflows/abbey-ci.yml`, Linux job (`ubuntu-latest` + `docker run swiftlang/swift:nightly-6.4.x-bookworm` — official `library/swift:6.4-*` not published yet) builds `web/` (bun), runs dashboard SPA tests, then builds `AbbeyCore`/`AbbeyServerKit`/`AbbeyServer`/`AbbeyCLI` and runs `AbbeyCoreTests`/`AbbeyCLITests`/`AbbeyServerKitTests`. Desktop job disabled (`if: false`) pending a self-hosted macOS 27 runner — GitHub-hosted `macos-*` runners don't satisfy the pin.

**GitHub Actions (private repo):** hosted workflows currently fail at **startup** with **0 jobs** until Billing → Actions spending/quota is enabled for this repository. Until then, **`bash Scripts/verify-all.sh` is the gate of record** (not a green CI badge). After billing is unblocked, re-run the **Abbey CI** (`abbey-ci`) workflow on the branch under test.

## Discord live path (desktop)

1. Developer Portal bot + Message Content intent
2. Discord tab → paste token (Keychain) → Connect
3. Optional: Dev guild ID → Register slash commands
4. Settings operating mode `liveDiscord` + auto-connect optional

## UI surfaces (shipped)

| Surface | What exists |
|---------|-------------|
| Desktop sidebar | Dashboard, Discord, Users (`HSplitView`), Channels, Messages, **Interactions**, Personas, Equity Research |
| Desktop Settings | Human titles for modes/options; Server sync shows last success/failure this session |
| SPA `/dashboard` | Tabs: Overview, Users, Channels, Messages, Reputation, **Interactions**, Equity (disclaimer); teal ops theme; list load-more capped at 500 |
| Leaf `GET /` | Grouped **Operator UI** + **JSON API** nav; Dashboard SPA link when `Public/index.html` exists, else “run `bun run build` in `web/`” |

## Server ops

Env: see `.env.example` (`DISCORD_BOT_TOKEN`, `DISCORD_DEV_GUILD_ID`, `DATABASE_URL`).

`DATABASE_URL`: `postgres://…` / `postgresql://…`, `sqlite://memory` / `sqlite::memory:`, or `sqlite:///path`. Boot logs `Database dialect: postgres|sqlite-memory|sqlite-file`.

```bash
docker compose up -d db          # Postgres 16
/usr/bin/xcrun --toolchain default swift run AbbeyServer serve --hostname 0.0.0.0 --port 8080
# or: docker compose up --build
# without Docker: DATABASE_URL=sqlite://${TMPDIR}/abbey.sqlite …
```

Routes: `GET /health`, `GET /dashboard` (React SPA when `web/` is built into `Sources/AbbeyServer/Resources/Public/`), `GET /api/metrics`, `GET /api/status`, `POST /api/ingest` / `POST /api/state/*` / list `GET /api/users|channels|messages|reputation|interactions|equity` (optional `ABBEY_API_TOKEN` when set — Bearer or `X-Abbey-Token`; leave unset for open local SPA list tabs), `GET /api/state/user|channel`, `GET /` (Leaf: Operator UI + JSON API; dashboard link only if built). Optional `?limit=` (default 100, max 500) on list endpoints.

Deploy: `Dockerfile` (Bun SPA stage → `swiftlang/swift:nightly-6.4.x-bookworm`, copies `AbbeyBot_AbbeyServer.resources`), `docker-compose.yml`, `deploy/abbeybot.service`. Presence activity: bridge default `"AbbeyBot"`; server passes `"AbbeyServer"`. Linux CI (`abbey-ci.yml`) builds `web/` with Bun (frozen lockfile + `bun test` + `bun run build`) before the Swift docker build so SPM packs dashboard assets.

Server smoke (`Scripts/run-server-smoke.sh`) uses compose Postgres when Docker is up; otherwise `sqlite://` file under `$TMPDIR` (`${TMPDIR}/AbbeyBot.server.build`). Asserts `/health`, Leaf `GET /`, `/dashboard` (200 if built, 404 skip if not), `/api/status`, `POST /api/ingest`, list endpoints, and `/api/state` remember/user/channel.

Desktop optional sync: Settings → Server sync (`ABBEY_SYNC_SERVER_URL` / `ABBEY_SYNC_API_TOKEN`) — best-effort **push** (ingest/remember/forget) plus **pull** on launch and Settings “Pull now” (server-wins users/channels/equity; messages insert-if-missing by Discord id; reputation/interactions insert-if-missing by Fluent `id`→`serverId`, rows without id skipped; limit 500). Failures never block local SwiftData writes; Settings shows last push/pull outcome for the session.

## CLI ops

```bash
bash Scripts/run-abbey.sh
```

Default local DB: `~/.abbey/abbey.sqlite` (directory auto-created), single-user, independent of the server's Postgres. `DATABASE_URL` overrides using the same convention as the server. Discord connects live under the same `DISCORD_BOT_TOKEN` / `DISCORD_DEV_GUILD_ID` env vars as the server when set; otherwise local-only with a warning logged.

## Shared core (finalized)

`AbbeyCore` owns `IngestScorer`, `ReputationMath`, `ReplyCooldownTracker`, `ChannelSummaryBuilder`, `PersonaName` / `MemoryFactText`, `DiscordCopy`, and strict-by-default `IntentClassifier`. Desktop `AbbeyEngine` and server `BotRuntime` keep persistence adapters only.

## Learning & Safety Policy

Binds the Abbey self-learning system prompt for operators, agents, and implementers. Prioritize **care, clarity, and competence**. Never treat RL rewards as permission to ignore safety.

### Mission

Operate as a safe, useful, continuously improving community assistant. Learn from explicit user feedback, moderation outcomes, retrieval success, and testable system signals. Never silently execute generated code, never bypass platform rules, and never treat reinforcement learning rewards as permission to ignore safety constraints.

### Reinforcement learning (strategy only)

`DQNAgent` in AbbeyCore drives strategy selection among allowed actions (answer, clarify, retrieve, refuse, etc.). RL improves routing among those actions; it does **not** weaken safety rules, confirmation gates, or platform policy. Hard constraints stay hard regardless of reward signal.

### Phase 1 runtime (shipped)

| Principle | Behavior |
|-----------|----------|
| Config validate before startup | `AppConfig.validateForStartup(scope:)` — `.desktop` (GUI) enforces `liveDiscord` token unless dry-run; `.headless` (server/CLI via `configureRuntime`) skips that UserDefaults gate so HTTP can boot without a token. Also: remoteCompatible URL; sync URL http(s)+host; cooldown/decay ranges. |
| Dry-run | `ABBEY_DRY_RUN=1` / `AppConfig.dryRun` — `DiscordBridge.connect` skips gateway, logs `dry-run: would connect`, sets state connected with `botUserId=dry-run`. |
| Durable checkpoints | `DQNAgent.save/load` + `DQNCheckpointStore` default `~/.abbey/dqn-checkpoint.json`; `*.bak` before overwrite; load on engine start; save every 100 learn steps with target sync. |
| Experience append-only default | Replay buffer remains **in-memory** for Phase 1; durable append-only experience journal is Phase 2 — do not claim it. |

### Toolchain / run UX

- Bare `swift run` fails (three products) — use `Scripts/run.sh` / `run-server.sh` / `run-abbey.sh` or name `AbbeyBot` \| `AbbeyServer` \| `abbey`.
- Desktop **requires Xcode** (`Scripts/run.sh`). Swiftly DEVELOPMENT-SNAPSHOT breaks SwiftData `@Query`.
- Server/CLI may use global swiftly: `ABBEY_SWIFT=swiftly bash Scripts/run-server.sh` (builds under `${TMPDIR}/AbbeyBot.swiftly.*.build`).

### Verification gate = release authority

`bash Scripts/verify-all.sh` (or the narrowest honest smoke for the change) is the gate of record. Static and security failures must pass or be documented as accepted exceptions before ship. GitHub Actions (`abbey-ci`) is secondary until billing is unblocked.

### Deferred (roadmap — not Phase 1)

- **Twitch** — IRC/EventSub client; no Twitch routes or APIs in this repo yet.
- **Generated-code safety validator** — proposals must pass validation before acceptance; no sandbox shipped yet.
- **Rollback FS** — full stateful rollback beyond checkpoint `*.bak` backup-before-overwrite.

## Deferred

Discord Voice **audio** (Opus/UDP) — DiscordBM has no media stack yet. Voice **presence** (`/voice join|leave`, Discord tab) is shipped.

Full CRDT / cursor pagination / CLI↔desktop sync — desktop ships **push + pull** (launch + Settings “Pull now”; server-wins users/channels/equity; messages by Discord id; reputation/interactions by Fluent id; limit 500). No CRDT merge and no `?since=` cursors.
