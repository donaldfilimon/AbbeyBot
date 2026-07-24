# AGENTS.md — AbbeyBot

Unified Abbey bot at `~/Desktop/AbbeyBot` — **two products** in one package. **macOS 27**.

## Stack

| Product | Target | Store | UI |
|---------|--------|-------|-----|
| Desktop | `AbbeyBot` (`AbbeyBotApp`) | SwiftData | SwiftUI |
| Server | `AbbeyServer` | Fluent + Postgres (SQLite smoke fallback) | Leaf status + `/api/*` + `/dashboard` SPA |
| CLI | `abbey` (`AbbeyCLI` via `swift run AbbeyBot cli`) | SQLite (local, `~/.abbey/`) | Terminal REPL |

Shared: `AbbeyCore` (personas, inference, DiscordBM bridge, DQN) and `AbbeyServerKit` (Fluent-backed engine used by `AbbeyServer` + `abbey`). One executable product `AbbeyBot` (`AbbeyEntry`). Swift 6.4 language mode; desktop requires Xcode toolchain (`xcrun --toolchain default` — swiftly DEVELOPMENT-SNAPSHOT breaks SwiftData macros).

## Verify

```bash
unset TOOLCHAINS
# Raw SPM UX with Desktop-safe build dir (preferred over bare `swift run` on Desktop/iCloud):
bash Scripts/swift-run.sh help
# Equivalent:
# /usr/bin/xcrun --toolchain default swift run --build-path "${TMPDIR}/AbbeyBot.build" AbbeyBot help

bash Scripts/run-smoke.sh          # desktop build/test/launch
bash Scripts/run-server-smoke.sh   # AbbeyServer + compose Postgres or sqlite file + GET /health
bash Scripts/run-cli-smoke.sh      # abbey CLI boot + DATABASE_URL isolation
bash Scripts/verify-all.sh         # all gates
```

Launch wrappers (Xcode toolchain):

```bash
bash Scripts/swift-run.sh    # desktop (pass serve|cli|help as args)
bash Scripts/run.sh          # desktop
bash Scripts/run-server.sh   # server (loads .env if present)
bash Scripts/run-abbey.sh    # abbey CLI (loads .env if present)
```

Bare `swift run` works when using the Xcode toolchain and `--build-path "${TMPDIR}/AbbeyBot.build"` (Desktop trees otherwise hit iCloud xattr codesign failures). Do not use PATH swiftly for the GUI.
Build paths use `${TMPDIR}/AbbeyBot*.build` to avoid Desktop/iCloud xattr codesign failures.

CI: `.github/workflows/abbey-ci.yml`, Linux job (`ubuntu-latest` + `docker run swiftlang/swift:nightly-6.4.x-bookworm` — official `library/swift:6.4-*` not published yet) builds `web/` (bun), runs dashboard SPA tests, then builds product `AbbeyBot` with `ABBEY_PACKAGE_ROLE=server` and runs `AbbeyCoreTests`/`AbbeyCLITests`/`AbbeyServerKitTests`. Desktop job disabled (`if: false`) pending a self-hosted macOS 27 runner — GitHub-hosted `macos-*` runners don't satisfy the pin.

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
ABBEY_PACKAGE_ROLE=server /usr/bin/xcrun --toolchain default swift run AbbeyBot serve --hostname 0.0.0.0 --port 8080
# or: docker compose up --build
# without Docker: DATABASE_URL=sqlite://${TMPDIR}/abbey.sqlite …
```

Routes: `GET /health`, `GET /dashboard` (React SPA when `web/` is built into `Sources/AbbeyServer/Resources/Public/`), `GET /api/metrics`, `GET /api/status`, `GET /api/sync-status` (last desktop-reported sync outcome — Sync tab), `POST /api/ingest` / `POST /api/state/*` (`remember`/`forget`/`sync-status`) / list `GET /api/users|channels|messages|reputation|interactions|equity` (optional `ABBEY_API_TOKEN` when set — Bearer or `X-Abbey-Token`; leave unset for open local SPA list tabs), `GET /api/state/user|channel`, `GET /` (Leaf: Operator UI + JSON API; dashboard link only if built). Optional `?limit=` (default 100, max 500) and `?since=<unix epoch seconds>` (incremental cursor) on list endpoints.

Deploy: `Dockerfile` (Bun SPA stage → `swiftlang/swift:nightly-6.4.x-bookworm`, copies `AbbeyBot_AbbeyServer.resources`), `docker-compose.yml`, `deploy/abbeybot.service`. Presence activity: bridge default `"AbbeyBot"`; server passes `"AbbeyServer"`. Linux CI (`abbey-ci.yml`) builds `web/` with Bun (frozen lockfile + `bun test` + `bun run build`) before the Swift docker build so SPM packs dashboard assets.

Server smoke (`Scripts/run-server-smoke.sh`) uses compose Postgres when Docker is up; otherwise `sqlite://` file under `$TMPDIR` (`${TMPDIR}/AbbeyBot.server.build`). Asserts `/health`, Leaf `GET /`, `/dashboard` (200 if built, 404 skip if not), `/api/status`, `POST /api/ingest`, list endpoints, and `/api/state` remember/user/channel.

Desktop optional sync: Settings → Server sync (`ABBEY_SYNC_SERVER_URL` / `ABBEY_SYNC_API_TOKEN`) — durable **push** (ingest/remember/forget/sync-status; failed POSTs retry via a JSONL outbox at `~/.abbey/pending-pushes.jsonl`, flushed on the next pull attempt) plus **pull** on launch and Settings “Pull now”, using `?since=` cursors to fetch only rows changed since the last pull. Users/channels use **last-write-wins by `updatedAt`** (an unsynced local edit newer than the remote row survives instead of being clobbered — not resilient to clock skew); equity uses the same rule keyed on `generatedAt` (ideas are regenerated, not edited, so the more recently generated idea for a symbol wins); messages insert-if-missing by Discord id; reputation/interactions insert-if-missing by Fluent `id`→`serverId`, rows without id skipped; limit 500. Failures never block local SwiftData writes; Settings shows last push/pull outcome for the session, and the SPA's Sync tab shows the server's view of the same (desktop-reported).

## CLI ops

```bash
bash Scripts/run-abbey.sh
# share server DATABASE_URL from .env (Postgres/sqlite):
ABBEY_CLI_USE_SERVER_DATABASE=1 bash Scripts/run-abbey.sh
```

Default local DB: `~/.abbey/abbey.sqlite` (directory auto-created), single-user, independent of the server's Postgres. `Scripts/run-abbey.sh` sources `.env` for Discord/`ABBEY_*` knobs but **clears `DATABASE_URL` unless** `ABBEY_CLI_USE_SERVER_DATABASE=1`. To override without the wrapper, export `DATABASE_URL` (same postgres/sqlite conventions as the server) before `swift run AbbeyBot cli`. Discord connects live under the same `DISCORD_BOT_TOKEN` / `DISCORD_DEV_GUILD_ID` env vars as the server when set; otherwise local-only with a warning logged.

## Shared core (finalized)

`AbbeyCore` owns `IngestScorer`, `ReputationMath`, `ReplyCooldownTracker`, `ChannelSummaryBuilder`, `PersonaName` / `MemoryFactText`, `DiscordCopy`, and strict-by-default `IntentClassifier`. Desktop `AbbeyEngine` and server `BotRuntime` keep persistence adapters only.

## Multi-Persona (claim-honest)

Three personas ship in AbbeyCore as `AbbeyPersona`, `AvivaPersona`, and `AbiPersona` (`Sources/AbbeyCore/Personas/`). Modulation is **AbbeyCore-only** — intent routing and explicit switch in `ABIRouter`; not a separate WDBX product or Python ML stack.

| Persona | Framework role | Shipped behavior |
|---------|----------------|------------------|
| **Abbey** | Ethical, professional community interaction | Default persona; direct community register (`AbbeyPersona.systemPrompt`) |
| **Aviva** | Analytical, research, architecture | Structured system-builder register — server architecture, permissions, moderation policy, code (`AvivaPersona`) |
| **Abi** | Moderation / compliance oversight tone | Platform rules, proportionate responses, escalation (`AbiPersona`) |

**Switch paths (shipped):**

- Discord slash `/persona` (`CommandRegistry` → `InteractionRouter` → `ABIRouter.setPersona`)
- Natural-language persona switch on ingest (`IntentClassifier.personaSwitch` → `PersonaName.resolve`)
- Desktop **Personas** tab (`PersonaSwitcherView`)

**Intent routing (`ABIRouter.route(intent:)`):** `.modRequest` / `.command` → Abi; `.question` → Aviva; `.greeting` / `.smallTalk` → Abbey; otherwise the active persona. DQN (`DQNAgent`) selects **strategy** among allowed actions only — see Learning & Safety Policy; do not claim a 10k req/s WDBX inference engine here.

**Live dispatch:** `AbbeyEngine` and `BotRuntime` call `ABIRouter.route(intent:)` (via `IntentClassifier`) on message ingress `craftReply` and slash `/ask` — not only `currentPersona()`.

**Roles reference:** `research_mlai.md` (Abbey-Aviva-Abi framework §2) is the role/policy source of truth only; do not port WDBX throughput, Python stack, or industry pilot claims as AbbeyBot product features.

**Not shipped (do not claim as product features):** Python persona framework, TensorFlow/PyTorch stack, live blockchain decentralization, industry healthcare/finance pilots as certified products, GDPR certification, or HIPAA compliance modules. `IndustryProfile` / `WDBXMemoryFacade` / `DecentralizationPolicy` are claim-honest shells only (see Phase 2).

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
| Dry-run | `ABBEY_DRY_RUN=1` / `AppConfig.dryRun` — `DiscordBridge` / `TwitchBridge` skip sockets, log `dry-run: would connect`. |
| Durable checkpoints | `DQNAgent.save/load` + `DQNCheckpointStore` default `~/.abbey/dqn-checkpoint.json`; `*.bak` before overwrite; load on engine start; save every 100 learn steps with target sync. |

### Phase 2 runtime (shipped)

| Principle | Behavior |
|-----------|----------|
| Experience journal | Append-only JSONL `~/.abbey/dqn-experience.jsonl` via `ExperienceJournal`; `DQNAgent.remember` appends; engines call `loadExperienceJournalIfPresent()` on start into the in-memory replay buffer. |
| Generated-code validator | `CodeProposalValidator.validate` / `acceptOrThrow` — static reject of shell/process/dlopen/network/rm patterns (not a sandbox). |
| Rollback FS | `RollbackStore` snapshots under `~/.abbey/rollback/<name>/`; `restore` / `restoreFromBak`; checkpoint saves also snapshot when managed. |
| Twitch IRC + chat→ingest/reply | `TwitchBridge` + `TwitchIRCParser` — PRIVMSG → ingest (`guildId=twitch`) + persona reply via IRC; dry-run logs sends. EventSub: `POST /api/twitch/eventsub` verifies HMAC-SHA256 (`Twitch-Eventsub-Message-Signature`, `TwitchEventSubSignature` in AbbeyServerKit) plus a 10-min replay window when `TWITCH_EVENTSUB_SECRET` is set (unset skips verification, logs a warning); rejects with 403 on mismatch. `TwitchHelixClient` (AbbeyServerKit) can fetch an app access token and create subscriptions via Helix, but is not wired to server boot and has not been run against live Twitch — needs a real public HTTPS callback this environment doesn't have. **Not shipped:** message-id replay dedup, per-event-type business logic, auto-subscribe on boot, PubSub. |
| Industry profile shell | `IndustryProfile` (`ABBEY_INDUSTRY_PROFILE`) — prompt suffix only; not HIPAA/GDPR product modules. |
| WDBX memory facade | `WDBXMemoryFacade` over `ExperienceJournal` — local strategy memory name only; **not** Zig abi WDBX; no throughput claims. |
| Decentralization stub | `DecentralizationPolicy` / `ABBEY_DECENTRALIZATION_ENABLED` — must stay false; startup validates. No blockchain node. |

### Toolchain / run UX

- Bare `swift run` → desktop (sole product `AbbeyBot`). Server/CLI: `swift run AbbeyBot serve` / `swift run AbbeyBot cli` (or wrappers). Linux/Docker/swiftly: `ABBEY_PACKAGE_ROLE=server`.
- Desktop **requires Xcode** (`Scripts/run.sh`). Swiftly DEVELOPMENT-SNAPSHOT breaks SwiftData `@Query`.
- Server/CLI may use global swiftly: `ABBEY_SWIFT=swiftly bash Scripts/run-server.sh` (builds under `${TMPDIR}/AbbeyBot.swiftly.*.build`).

### Verification gate = release authority

`bash Scripts/verify-all.sh` (or the narrowest honest smoke for the change) is the gate of record. Static and security failures must pass or be documented as accepted exceptions before ship. GitHub Actions (`abbey-ci`) is secondary until billing is unblocked.

### Still deferred

- **Twitch EventSub full lifecycle / PubSub** — HMAC signature verification (with replay window) and a reusable Helix subscribe client ship (see Phase 2 table). Still deferred: message-id replay dedup, per-event-type business logic, auto-subscribe on server boot, PubSub. The subscribe flow is unverified against Twitch's live API — it needs a real public callback URL to exercise the `webhook_callback_verification` handshake, which this environment can't provide.
- **Codegen sandbox** — static `CodeProposalValidator` only; no isolated execution sandbox.
- **Real WDBX / blockchain** — facade + policy stubs only; Zig abi WDBX and chain nodes are out of this package.
- Full CRDT merge, delete propagation, CLI↔desktop sync — see Deferred below (`?since=` cursors and last-write-wins for users/channels now ship).

## Deferred

Discord Voice **audio** (Opus/UDP) — DiscordBM has no media stack yet, and a real implementation (Voice Gateway WS + UDP/IP-discovery + RTP + Opus codec + audio capture/playback) is a standalone effort on the order of the rest of this package combined. Deliberately out of scope; not planned alongside other sync/UI work. Voice **presence** (`/voice join|leave`, Discord tab) is shipped.

Full CRDT / CLI↔desktop sync — desktop ships **push + pull** with `?since=` incremental cursors (launch + Settings “Pull now”) and **last-write-wins** for users/channels (by `updatedAt`) and equity (by `generatedAt`); messages by Discord id; reputation/interactions by Fluent id; limit 500. LWW compares each side's own wall clock — not resilient to significant clock skew between desktop and server. No CRDT merge, no delete/tombstone propagation, and the CLI still doesn't participate in sync at all (`abbey` is local-SQLite-only per its own DATABASE_URL section above).
