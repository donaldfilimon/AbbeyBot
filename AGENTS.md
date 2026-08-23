# AGENTS.md — AbbeyBot

Unified Abbey bot at `~/dev/active/AbbeyBot` — **two products** in one package. **macOS 27**.

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
# Raw SPM UX with a checkout-safe build dir (preferred over bare `swift run`):
bash Scripts/swift-run.sh help
# Equivalent:
# /usr/bin/xcrun --toolchain default swift run --build-path "${TMPDIR}/AbbeyBot.build" AbbeyBot help

bash Scripts/check-static-security.sh # diff/conflict/secret hygiene
bash Scripts/run-web-smoke.sh      # SPA lint/test/build + packed-resource assertion
bash Scripts/run-smoke.sh          # all five Swift test bundles + desktop build/launch
bash Scripts/run-server-smoke.sh   # AbbeyServer + compose Postgres or sqlite file + GET /health
bash Scripts/run-cli-smoke.sh      # abbey CLI boot + DATABASE_URL isolation
bash Scripts/check-server-snapshot.sh # server graph under a swiftly nightly (builds + runs CI's four test filters)
bash Scripts/check-server-linux.sh    # server graph cross-compiled for Linux (musl static SDK; product only, no tests)
bash Scripts/verify-all.sh         # all gates
```

Launch wrappers (Xcode toolchain):

```bash
bash Scripts/swift-run.sh    # desktop (pass serve|cli|help as args)
bash Scripts/run.sh          # desktop
bash Scripts/run-server.sh   # server (loads .env if present)
bash Scripts/run-abbey.sh    # abbey CLI (loads .env if present)
```

Bare `swift run` fails when `TOOLCHAINS=swift` (swiftly / DEVELOPMENT-SNAPSHOT) is exported — SwiftData `@Query` / `\.modelContext` break. Prefer `bash Scripts/run.sh` or `bash Scripts/swift-run.sh` (both `unset TOOLCHAINS` + Xcode). Build paths use `${TMPDIR}/AbbeyBot*.build` to keep build output outside the checkout and avoid extended-attribute codesign failures.

## Browserbase Functions (`functions/`)

Optional serverless browser automation (not part of `verify-all`). Bun package; starter scrapes HN. Setup: `cd functions && cp .env.example .env` (fill `BROWSERBASE_*` from https://browserbase.com/settings), then `bun run dev` / `bun run deploy`. See `functions/README.md`.

CI: `.github/workflows/abbey-ci.yml`, Linux job (`ubuntu-latest` + `docker run swiftlang/swift:nightly-6.4.x-bookworm` — official `library/swift:6.4-*` not published yet) runs the static/security check, lints/tests/builds `web/`, then builds product `AbbeyBot` with `ABBEY_PACKAGE_ROLE=server` and runs `AbbeyCoreTests`/`AbbeyCLITests`/`AbbeyServerKitTests`/`AbbeyServerTests`. Desktop job disabled (`if: false`) pending a self-hosted macOS 27 runner — GitHub-hosted `macos-*` runners don't satisfy the pin.

### Server-graph snapshot parity

`bash Scripts/check-server-snapshot.sh` builds and tests the **server** graph (`ABBEY_PACKAGE_ROLE=server`) locally under a swiftly-managed Swift development snapshot, mirroring the Linux CI job: resolve → `swift build --product AbbeyBot` → the four CI test filters (`AbbeyServerKitTests` with `DATABASE_URL=sqlite://memory`; the other three without it, exactly like CI). It auto-picks the newest installed `main-snapshot-*` (override: `ABBEY_SNAPSHOT_TOOLCHAIN=...`), selects it **per-invocation only** via swiftly's `+toolchain` selector, writes each gate's output to a log, and echoes the real exit code per gate. Build scratch lives under `${TMPDIR}` like the other scripts.

Hard rules: the swiftly global default is never changed, and **desktop work must never use snapshot toolchains** — the desktop target REQUIRES the Xcode toolchain (SwiftData macros and codesigning break under DEVELOPMENT-SNAPSHOT toolchains). This script exists only so server-graph changes can be checked against the same nightly-6.4.x-line compiler CI uses without waiting on Docker/Actions.

### Server-graph Linux cross-compile

`bash Scripts/check-server-linux.sh` **cross-compiles** the server graph for Linux on this Mac, so a "Darwin provides something Linux does not" break is found in minutes instead of ~18 per Actions round trip. This machine has no container runtime (no `docker`/`colima`/`podman`), so a swift.org **Static Linux SDK** is the mechanism. Gates: `package resolve` → `swift build --product AbbeyBot` → a `glibc-divergence` static lint. Same conventions as the snapshot script: pinned per-invocation `+toolchain`, a log per gate, real exit codes echoed, scratch under `${TMPDIR}`, exit 69 when the toolchain or SDK is missing.

Setup is in the script's header and is a one-time cost: `swiftly install main-snapshot-2026-07-11`, then download `swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a_static-linux-0.1.0.artifactbundle.tar.gz` from `download.swift.org`, `gpg --verify` it against `https://swift.org/keys/all-keys.asc` (expect "Swift Automatic Signing Key #4"), and `swift sdk install` it. **The SDK version must match the toolchain version** — that is why the toolchain is hard-pinned here rather than auto-picked like the snapshot script does; pairing the newest installed snapshot with an older SDK fails confusingly at build time. Overrides: `ABBEY_LINUX_TOOLCHAIN`, `ABBEY_LINUX_SWIFT_SDK`, `ABBEY_LINUX_SDK_BUNDLE`.

**Two limits, both load-bearing — this script does not predict CI on its own:**

- **musl, not glibc.** The Static Linux SDK is musl; CI's `swiftlang/swift:nightly-6.4.x-bookworm` is glibc. The gap is not theoretical: glibc declares `extern FILE *stderr;` (mutable global → Swift 6 strict concurrency rejects every reference) while musl declares `extern FILE *const stderr;` (a `let`, compiles clean). A musl-green build hid exactly that break in `Sources/AbbeyEntry/main.swift`. The `glibc-divergence` gate statically flags references to `stdin`/`stdout`/`stderr` (use `FileHandle.standardError`/`.standardOutput` instead) and warns about `canImport(Glibc)` branches that lack a `canImport(Musl)` companion, since this SDK does not compile them.
- **No tests.** The Static Linux SDK ships no `Testing` and no `XCTest` module, so `swift build --build-tests` cannot even compile the test targets. Test sources are covered natively by `check-server-snapshot.sh`.

The two scripts are **complementary, not redundant**: snapshot = macOS host, nightly compiler, builds *and runs* the four CI test filters; linux = real Linux target, product graph only. Neither is the gate of record.

**`.swift-version` is machine-local and gitignored — never commit it.** On macOS dev machines keep an untracked `.swift-version` containing `xcode` at the repo root: it pins swiftly-proxied `swift` to the Xcode toolchain, which protects the desktop path (do NOT rely on the swiftly global default for this — on the primary dev machine that default is a main snapshot, not xcode). It must not be tracked because `xcode` is a macOS-only swiftly selector: on Linux a committed copy breaks every swiftly-proxied invocation (`ABBEY_SWIFT=swiftly bash Scripts/run-abbey.sh` → "version xcode ... doesn't match any of the installed toolchains"). Linux checkouts simply have no `.swift-version` and fall back to that machine's swiftly default; CI uses the Docker image and never consults swiftly. `check-server-snapshot.sh` is unaffected either way — its explicit `+toolchain` selector overrides `.swift-version`. If a branch has committed `.swift-version` (e.g. the phase-4 voice branch), drop it at reconcile with `git rm --cached .swift-version` — the local file stays on disk.

**Gate of record:** `bash Scripts/verify-all.sh` (or the narrowest honest smoke for the change). Static and security failures must pass or be documented as accepted exceptions before ship. **GitHub Actions (`abbey-ci`)** is secondary until billing is unblocked — hosted workflows currently fail at **startup** with **0 jobs** until Billing → Actions spending/quota is enabled; re-run Abbey CI after unblock.

**Continuation:** “finish all”, “do all”, “continue”, “continue with all”, and equivalent requests mean run the narrowest honest gate for the scoped change plus any ship steps the user asked for — not an intermediate green alone.

**Narrow smokes:** desktop → `run-smoke.sh`; server → `run-server-smoke.sh`; CLI → `run-cli-smoke.sh`.

## Discord live path (desktop)

1. Developer Portal bot + Message Content intent
2. Discord tab → paste token (Keychain) → Connect
3. Optional: Dev guild ID → Register slash commands
4. Settings operating mode `liveDiscord` + auto-connect optional

### Social APIs (Twitch + multi-network understanding)

| Surface | Shipped |
|---------|---------|
| Twitch IRC + EventSub chat/stream | Yes — ingest/reply; HMAC webhook |
| Twitch follow/subscribe/cheer | Yes — parse + interaction log + soft ingest |
| Helix users/streams | Client methods (unit-testable; live needs creds) |
| Social catalog | `GET /api/social/catalog` (+ markdown) |
| YouTube / X / Bluesky / Mastodon webhooks | `POST /api/social/{platform}/webhook` parsers → ingest (not full live SDKs) |

PubSub won't ship. Live EventSub handshake still needs public HTTPS.

### Slash surface (desktop + server)

| Command | Backend path |
|---------|----------------|
| `/ask`, `/explain`, `/summarize` | Active persona + `InferenceRouter` (Foundation Models when `inferenceMode=onDevice`, else remote / deterministic floor) |
| `/model [ondevice\|remote\|floor]` | `AppConfig.inferenceMode` |
| `/status` | Persona, Discord state, metrics, industry, equity flag, dry-run |
| `/rep`, `/facts`, `/remember`, `/forget`, `/context` | Social brain / memory (SwiftData or Fluent) |
| `/persona` | Abbey / Aviva / Abi |
| `/mod` | Abi moderation **advice only** (does not kick/ban) |
| `/equity` | Synthetic `FactorScreen` when equity module enabled — not market data |
| `/industry`, `/ping`, `/help` | Config / health / command list |
| `/voice join\|leave` | Gateway **presence** only today; real audio is **in progress**, not shipped |

Re-register slash commands after upgrade so Discord sees the expanded set.

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

Routes: `GET /health`, `GET /dashboard` (React SPA when `web/` is built into `Sources/AbbeyServer/Resources/Public/`), `GET /api/metrics`, `GET /api/status`, `GET /api/sync-status` (last desktop-reported sync outcome — Sync tab), `POST /api/ingest` / `POST /api/state/*` (`remember`/`forget`/`tombstone/{user,channel,message,reputation,interaction,equity}`/`sync-status`) / list `GET /api/users|channels|messages|reputation|interactions|equity` / keyed `GET /api/state/user|channel`, `GET /` (Leaf: Operator UI + JSON API; dashboard link only if built). `ABBEY_API_TOKEN` is required for the operator root and the grouped operator/state/sync/ingest/catalog `/api` routes; absent or blank server configuration returns 503, while a configured server returns 401 to missing/wrong Bearer or `X-Abbey-Token` callers. `GET /health`, static `/dashboard`, and Twitch EventSub's separately signed native webhook retain their own policies. Generic unsigned social webhooks remain closed behind the configured operator token except for their explicit testing/dry-run bypass. Optional `?limit=` (default 100, max 500) and `?since=<unix epoch seconds>` (incremental cursor) on list endpoints. `Tests/AbbeyServerTests/` exercises this route layer directly through real `VaporTesting` requests.

Deploy: `Dockerfile` (Bun SPA stage → `swiftlang/swift:nightly-6.4.x-bookworm`, copies `AbbeyBot_AbbeyServer.resources`), `docker-compose.yml`, `deploy/abbeybot.service`. Presence activity: bridge default `"AbbeyBot"`; server passes `"AbbeyServer"`. Linux CI (`abbey-ci.yml`) builds `web/` with Bun (frozen lockfile + `bun test` + `bun run build`) before the Swift docker build so SPM packs dashboard assets.

Server smoke (`Scripts/run-server-smoke.sh`) uses compose Postgres when Docker is up; otherwise `sqlite://` file under `$TMPDIR` (`${TMPDIR}/AbbeyBot.server.build`). It creates a per-run synthetic `ABBEY_API_TOKEN` only in the smoke process environment, sends it in request headers without printing it, and asserts `/health`, authenticated Leaf `GET /`, public `/dashboard` (200 if built, 404 skip if not), `/api/status`, `POST /api/ingest`, list endpoints, and `/api/state` remember/user/channel.

Desktop optional sync: Settings → Server sync (`ABBEY_SYNC_SERVER_URL` / `ABBEY_SYNC_API_TOKEN`) — durable **push** (ingest/remember/forget/sync-status; failed POSTs retry via a JSONL outbox at `~/.abbey/pending-pushes.jsonl`, flushed on the next pull attempt) plus **pull** on launch and Settings “Pull now”. Pulls use independent compound `(changedAt, stable ID)` cursors for users, channels, messages, reputation, interactions, and equity. Requests send `?since=<unix epoch>&after=<stable ID>`; list bodies remain JSON arrays and the server publishes the exact next boundary in `X-Abbey-Sync-Cursor-Time` / `X-Abbey-Sync-Cursor-ID` headers. `SyncCursorStore` persists the v2 cursor set in `UserDefaults`; an existing `abbey.sync.lastPullSuccessAt` timestamp is conservatively expanded across all six streams and rewritten after the next successful pull. Missing or corrupt state degrades to an oldest-first full bootstrap (`since=0`) rather than a bogus cursor. A short page advances that entity through pull start; a full 500-row page advances only through the server-issued last-row boundary, so overflow and more than 500 identical-timestamp changes drain without loss. Desktop and CLI share `SyncPullCursor`, `SyncPullCursorSet`, and `IncrementalSyncCursor`. Event/equity tombstones are ordered by `deletedAt`, so an old row deleted recently is not starved by its creation timestamp. The cursor never advances beyond pull start. **Residual clock caveat:** pull-start guards and LWW compare wall clocks, so a desktop clock ahead of the server can still skip later server writes until clocks converge. Users/channels use LWW by `updatedAt`; equity uses LWW by `generatedAt`. Full lists filter tombstones at SQL level; incremental lists include them so clients hard-delete local rows. Messages insert-if-missing by Discord ID; reputation/interactions insert-if-missing by Fluent ID; limit 500. Failures never advance cursors or block local SwiftData writes; Settings shows session outcomes and the SPA Sync tab shows the desktop-reported server view.

## CLI ops

```bash
bash Scripts/run-abbey.sh
# share server DATABASE_URL from .env (Postgres/sqlite):
ABBEY_CLI_USE_SERVER_DATABASE=1 bash Scripts/run-abbey.sh
```

Default local DB: `~/.abbey/abbey.sqlite` (directory auto-created), single-user, independent of the server's Postgres. `Scripts/run-abbey.sh` sources `.env` for Discord/`ABBEY_*` knobs but **clears `DATABASE_URL` unless** `ABBEY_CLI_USE_SERVER_DATABASE=1`. To override without the wrapper, export `DATABASE_URL` (same postgres/sqlite conventions as the server) before `swift run AbbeyBot cli`. Discord connects live under the same `DISCORD_BOT_TOKEN` / `DISCORD_DEV_GUILD_ID` env vars as the server when set; otherwise local-only with a warning logged.

REPL commands: `/help`, `/clear`, `/model [mode]`, `/validate <src>`, `/sync`, `/sync pull`, `/sync push`, `/exit`. `/sync` is **read-only** — it prints the desktop-reported `sync_status_records` row visible in the CLI's own database (`BotRuntime.syncStatusSnapshot()`). On the default local SQLite DB there is no such row, so it says so and points at `ABBEY_CLI_USE_SERVER_DATABASE=1`. `/sync pull` reads `ABBEY_SYNC_SERVER_URL` / `ABBEY_SYNC_API_TOKEN`, fetches all six list endpoints with the per-entity compound cursor set at `~/.abbey/cli-sync-cursor`, and applies rows via `ServerSyncApply` using the same LWW/tombstone rules as desktop `SyncPull`. A legacy one-line epoch cursor migrates automatically to the v2 JSON cursor set; progress advances only after a fully successful pull. `/sync push` pushes **messages + user memory facts only** to `POST /api/ingest` (preserving `discordMessageId`; duplicate skips are idempotent) and `POST /api/state/remember`, with a separate cursor at `~/.abbey/cli-sync-push-cursor`. Reputation/interactions are re-derived by ingest; equity and tombstones have no CLI write surface. Unconfigured URL prints how to configure instead of faking a sync.

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

**Intent routing (`ABIRouter.route(intent:)`):** `.modRequest` / `.command` → Abi; `.question` → Aviva; `.greeting` / `.smallTalk` → Abbey; otherwise the active persona. `DQNAgent` selects and dispatches a four-wide answer/clarify/retrieve/refuse strategy head. Do not claim delayed-feedback learning, a 10k req/s WDBX inference engine, or a separate model per persona.

**Live dispatch:** `AbbeyEngine` and `BotRuntime` call `ABIRouter.route(intent:)` (via `IntentClassifier`) on message ingress `craftReply` and slash `/ask` — not only `currentPersona()`.

**Roles reference:** `research_mlai.md` (Abbey-Aviva-Abi framework §2) is the role/policy source of truth only; do not port WDBX throughput, Python stack, or industry pilot claims as AbbeyBot product features.

**Not shipped (do not claim as product features):** Python persona framework, TensorFlow/PyTorch stack, live blockchain decentralization, industry healthcare/finance pilots as certified products, GDPR certification, or HIPAA compliance modules. `IndustryProfile` / `WDBXMemoryFacade` / `DecentralizationPolicy` are claim-honest shells only (see Phase 2).

## Learning & Safety Policy

Binds the Abbey self-learning system prompt for operators, agents, and implementers. Prioritize **care, clarity, and competence**. Never treat RL rewards as permission to ignore safety.

### Mission

Operate as a safe, useful, continuously improving community assistant. Learn from explicit user feedback, moderation outcomes, retrieval success, and testable system signals. Never silently execute generated code, never bypass platform rules, and never treat reinforcement learning rewards as permission to ignore safety constraints.

### Reinforcement learning (strategy dispatch — shipped)

`DQNAgent` topology **`[8, 64, 32, 4]`** selects `StrategyAction`: **answer / clarify / retrieve / refuse**. `IngestScorer.scoreAndLearn` records an **action-conditioned immediate heuristic reward** as a terminal contextual-bandit sample (`nextState == state`, `done == true`), trains a minibatch, and upserts the ingest vector into local WDBX. `craftReply` **routes on `lastStrategy`** (clarify prompts, scoped persisted-fact context for `.retrieve`, hard refuse for mod/command + `.refuse`). It does not yet learn from delayed reactions or moderation outcomes. Learning never weakens kick/ban gates.

**Neural acceleration:** `NeuralMath` / network dots use **Accelerate/vDSP** on Apple platforms (AMX/NEON) — not CUDA.
**Local WDBX:** `~/.abbey/wdbx/` segmented JSONL (`WDBXStore`) + experience journal. **Not** Zig abi WDBX; no throughput claims. Old checkpoints with `[8,32,16,3]` fail topology load and re-init.

### Phase 1 runtime (shipped)

| Principle | Behavior |
|-----------|----------|
| Config validate before startup | `AppConfig.validateForStartup(scope:)` — `.desktop` (GUI) enforces `liveDiscord` token unless dry-run; `.headless` (server/CLI via `configureRuntime`) skips that UserDefaults gate so HTTP can boot without a token. Also: remoteCompatible URL; sync URL http(s)+host; cooldown/decay ranges. |
| Dry-run | `ABBEY_DRY_RUN=1` / `AppConfig.dryRun` — `DiscordBridge` / `TwitchBridge` skip sockets, log `dry-run: would connect`. |
| Durable checkpoints | `DQNAgent.save/load` + `DQNCheckpointStore` default `~/.abbey/dqn-checkpoint.json`; `*.bak` before overwrite; load on engine start; save every 100 learn steps with target sync. |
| Correct backprop + full fan-in + Accelerate | Fan-in-correct dense layers + ReLU backprop (see `NeuralNetworkBackpropTests`). Dots via `NeuralMath` / Accelerate vDSP. Topology now `[8, 64, 32, 4]` with live strategy dispatch — see RL section above. |

### Phase 2 runtime (shipped)

| Principle | Behavior |
|-----------|----------|
| Experience journal | Append-only JSONL `~/.abbey/dqn-experience.jsonl` via `ExperienceJournal`; `DQNAgent.remember` appends; engines call `loadExperienceJournalIfPresent()` on start into the in-memory replay buffer. |
| Generated-code validator | `CodeProposalValidator.validate` / `acceptOrThrow` — static reject of shell/process/dlopen/network/rm patterns (not a sandbox). |
| Rollback FS | `RollbackStore` snapshots under `~/.abbey/rollback/<name>/`; `restore` / `restoreFromBak`; checkpoint saves also snapshot when managed. |
| Twitch IRC + chat→ingest/reply | `TwitchBridge` + `TwitchIRCParser` — PRIVMSG → ingest (`guildId=twitch`) + persona reply via IRC; dry-run logs sends. A clean peer-closed IRC connection correctly flips `state` to `.failed` with a descriptive `lastError` (verified with a real local-socket test, not a mock), and `TwitchBridge` then retries the connection itself with exponential backoff + jitter (2s base, 60s cap; both injectable for tests), cancelled cleanly by an explicit `disconnect()`. Caveat found while building this: a reconnect attempt launched from the internal retry `Task` was observed, in ad hoc local testing, taking far longer (~76s) to actually complete a connection than the original directly-awaited `connect()` call does (well under a second) — plausibly because `TwitchIRCConnection` never schedules its CFStreams on a run loop, but this is unconfirmed. Real-world reconnect latency may not match the nominal backoff schedule; this needs runtime observation against live Twitch to know for sure. IRC and EventSub chat share one path: `BotRuntime.handleTwitchChat` (bot-nick skip, ingest, cooldown, persona reply over IRC). EventSub: `POST /api/twitch/eventsub` verifies HMAC-SHA256 (`Twitch-Eventsub-Message-Signature`, `TwitchEventSubSignature` in AbbeyServerKit) plus a 10-min replay window when `TWITCH_EVENTSUB_SECRET` is set (unset skips verification, logs a warning); rejects with 403 on mismatch. Duplicate deliveries are dropped by `Twitch-Eventsub-Message-Id` via `TwitchEventSubReplayGuard`, backed by a Fluent `twitch_eventsub_deliveries` table (survives restarts and is shared across instances; the unique constraint on `message_id` is the claim, pruned on the same 10-min replay window) rather than in-process memory (challenge echoes skip claim so verification retries still work). `TwitchEventSubHandler` classifies message types; `channel.chat.message` → `handleTwitchChat` (ack `outcome=notification-ingested`); `stream.online` / `stream.offline` → `handleTwitchStreamLifecycle` (updates `BotRuntime.twitchStreamLive`, publishes `AbbeyEvent.twitchStreamLifecycle`, logs an interaction; surfaced on `GET /api/status` as `twitchStreamLive`) — follow/subscribe/cheer log interactions and soft-ingest social context. Auto-subscribe on boot ships **env-gated and off by default**: `TwitchEventSubAutoSubscriber` runs in `BotLifecycleHandler.didBootAsync` (server only, not CLI) when `ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE=1` plus `TWITCH_CLIENT_ID`/`TWITCH_CLIENT_SECRET`/`TWITCH_EVENTSUB_SECRET`/`TWITCH_EVENTSUB_CALLBACK_URL` (https only)/`TWITCH_BROADCASTER_USER_ID`/`TWITCH_BOT_USER_ID`/`TWITCH_EVENTSUB_AUTHORIZATION_CONFIRMED=1` are all set — it fetches an app token and reconciles `channel.chat.message`, `stream.online`, `stream.offline`, `channel.follow`, `channel.subscribe`, and `channel.cheer` via `TwitchHelixClient` (HTTP 409 is idempotent success); missing configuration, unconfirmed user authorization, or any Helix failure warns and skips without crashing boot. Chat authorization needs `user:read:chat` + `user:bot` from the bot and either broadcaster `channel:bot` or moderator status; follow/subscribe/cheer need their documented broadcaster/moderator scopes. The flow has not been run against live Twitch — the `webhook_callback_verification` handshake needs a real public HTTPS callback this environment doesn't have. **Not shipped:** PubSub (Twitch-deprecated; won't ship) or a live-verified Helix handshake. |
| Industry profile shell | `IndustryProfile` (`ABBEY_INDUSTRY_PROFILE`) — prompt suffix only; not HIPAA/GDPR product modules. |
| WDBX memory facade | `WDBXMemoryFacade` over `ExperienceJournal` — local strategy memory name only; **not** Zig abi WDBX; no throughput claims. |
| Decentralization stub | `DecentralizationPolicy` / `ABBEY_DECENTRALIZATION_ENABLED` — must stay false; startup validates. No blockchain node. |

### Toolchain / run UX

- Bare `swift run` → desktop (sole product `AbbeyBot`). Server/CLI: `swift run AbbeyBot serve` / `swift run AbbeyBot cli` (or wrappers). Linux/Docker/swiftly: `ABBEY_PACKAGE_ROLE=server`.
- Desktop **requires Xcode** (`Scripts/run.sh`). Swiftly DEVELOPMENT-SNAPSHOT breaks SwiftData `@Query`.
- Server/CLI may use global swiftly: `ABBEY_SWIFT=swiftly bash Scripts/run-server.sh` (builds under `${TMPDIR}/AbbeyBot.swiftly.*.build`).

### Verification gate = release authority

See **Verify** above — gate of record, CI secondary, continuation semantics, and narrow smoke scripts.

### Still deferred

- **Twitch EventSub live verification / PubSub** — HMAC signature verification (with replay window), message-id replay dedup (`TwitchEventSubReplayGuard`), typed `TwitchEventSubHandler` classification, chat/stream/follow/subscribe/cheer handling, env-gated six-type auto-subscribe reconciliation (`TwitchEventSubAutoSubscriber`, off by default), and a reusable Helix subscribe client ship (see Phase 2 table). Still deferred: running the authorization + `webhook_callback_verification` handshake against Twitch through a real public HTTPS callback. PubSub is a **won't-ship** — Twitch deprecated it in favor of EventSub.
- **Codegen sandbox** — **won't ship in this package**; `/validate` remains the static `CodeProposalValidator` reject-list only. An isolated execution sandbox would be a separate product surface; nothing here should scaffold or imply a jail.
- **Real WDBX / blockchain** — facade + policy stubs only; Zig abi WDBX and chain nodes are out of this package.
- **Discord Voice audio** — reopened and **in progress**. Presence (`/voice join|leave`) is currently
  shipped. Do not claim audio until Voice Gateway v8, UDP discovery, mandatory transport AEAD,
  DAVE E2EE, RTP/Opus send and receive, capture/playback, reconnect/resume, permissions/UI, tests,
  and a live DAVE-enabled call are verified. DiscordBM supplies the main-gateway event models and
  voice-state update, but not the separate media stack.
- **Discord video / Go Live** — reopened and **in progress**, independently from voice audio. No
  camera or screen-streaming product surface is shipped. Do not claim video until source/sink
  signaling, permission-gated camera/screen capture, negotiated codec/RTP send and receive, DAVE
  video frames, rendering/UI, congestion/loss/resource tests, and live DAVE-enabled camera plus Go
  Live evidence are verified.
- **CRDT merge** — **won't ship**; LWW + tombstones + CLI `/sync pull` + `/sync push` (messages + facts) is the sync story (see Deferred below). Multi-writer CRDT merge stays out.

## Deferred

Discord Voice **audio** — **in progress, not shipped.** Voice presence (`/voice join|leave`, Discord
tab) remains the only verified runtime claim. Current Discord participation requires the separate
Voice Gateway v8 connection, UDP/IP discovery, supported AEAD transport encryption, DAVE E2EE,
RTP/Opus send and receive, capture/playback, reconnect/resume, permission and privacy controls,
deterministic tests, and a live DAVE-enabled call. Do not convert roadmap code or a local transport
test into a shipped-audio claim; keep `tasks/goals.md` and `tasks/todo.md` as the completion ledger.

Discord **video and Go Live** — **in progress, not shipped.** Track video independently from audio.
Completion requires Voice Gateway source/sink signaling, explicit camera/screen permissions,
negotiated video codec/RTP send and receive, DAVE video-frame protection, render and SwiftUI
controls, congestion/loss/resource testing, and live DAVE-enabled camera plus Go Live evidence.
Scaffolds, fixture playback, or an audio-only live call do not prove video completion.

CRDT (won't ship) — desktop ships **push + pull** with persisted per-entity compound incremental cursors and **last-write-wins** for users/channels (`updatedAt`) and equity (`generatedAt`); all six sync entity types soft-delete via `deletedAt` tombstones that `SyncPull` applies as local hard-deletes; messages key by Discord ID and reputation/interactions by Fluent ID; page limit 500 drains through `(changedAt, stable ID)` continuation. LWW and pull-start guards compare wall clocks and remain vulnerable to significant clock skew. The CLI ships **pull + push** with the same compound pull protocol; push remains messages + memory facts only. True multi-writer CRDT/vector-clock merge remains a **won't-ship** for this package.

## Learned User Preferences

- Prefer terse, path-anchored findings and tables for gates/status; avoid narrative essay wrap-ups.
- Mid-task slash-skill attaches (`/review`, `/continual-learning`, etc.) win over inventing a parallel workflow.
- Dual review asks (“security and code quality”) mean run both Bugbot and Security Review.
- Prefer `cursor/` branches from `origin/main`, draft PRs when offered, land via PR merge; never commit/push straight to `main` or force-push `main`.

## Learned Workspace Facts

- Do not commit secrets (`.env`, tokens) or local scratch (`.cursor/hooks/`). Optional `functions/` Browserbase scaffold is tracked; keep `functions/.env` / `functions/node_modules` untracked (see `functions/.gitignore`).
- Do not commit `node_modules` — dashboard deps live under `web/node_modules` (`web/.gitignore`); Browserbase deps under `functions/node_modules`.
- Dashboard SPA build output packs into `Sources/AbbeyServer/Resources/Public/` (gitignored unless intentionally shipping built assets).
- Prefer repo launch wrappers (`Scripts/run.sh`, `run-server.sh`, `run-abbey.sh`, `swift-run.sh`) over hand-pasted multiline `xcrun`/`swift run` — terminal pastes often include editor line numbers or bare `--port` flags that fail.
- Process env overrides UserDefaults for `AppConfig` knobs (`ABBEY_INFERENCE_MODE`, etc.); smoke scripts pin `ABBEY_INFERENCE_MODE=deterministicFloor` and isolate `HOME` so host GUI settings cannot block headless boots.
