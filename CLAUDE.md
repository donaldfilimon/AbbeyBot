# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Full agent instructions (ops, personas, safety policy, deferred features) live in [`AGENTS.md`](./AGENTS.md) — **read that file before making non-trivial changes.** This file is a quick-reference layer on top of it.

Cursor uses a parallel persona at [`.cursor/agents/abbey.md`](./.cursor/agents/abbey.md) that mirrors AGENTS.md's verify gates, shipped/won't-ship lists, and toolchain rules — when those change here, update it too so the two don't drift.

All three products route through `AbbeyEntry` (the package's sole `@main`), which dispatches on the first argument (`serve` / `cli` / nothing → desktop).

## Commands

Always `unset TOOLCHAINS` first — desktop needs Xcode's toolchain, not a swiftly DEVELOPMENT-SNAPSHOT (breaks SwiftData `@Query` macros).

```bash
bash Scripts/verify-all.sh         # full gate — run before calling anything done
bash Scripts/check-static-security.sh # tracked-secret/conflict-marker/diff hygiene
bash Scripts/check-knowledge-snapshot.sh # signed bundled knowledge bytes + manifest
bash Scripts/run-web-smoke.sh      # dashboard lint + tests + production build
bash Scripts/run-smoke.sh          # desktop build/test/launch
bash Scripts/run-server-smoke.sh   # AbbeyServer + Postgres (compose) or sqlite fallback + GET /health
bash Scripts/run-cli-smoke.sh      # abbey CLI boot + DATABASE_URL isolation
bash Scripts/check-server-snapshot.sh # server graph under a swiftly nightly (builds + runs CI's four test filters)
bash Scripts/check-server-linux.sh    # server graph CROSS-COMPILED for Linux (musl static SDK; product only, no tests)
```

`check-server-linux.sh` is the fast way to catch a Linux-only break without an ~18-minute Actions round trip, but it is musl while CI is glibc, and it cannot compile test targets (the Static Linux SDK ships no `Testing`/`XCTest`). Read the "Server-graph Linux cross-compile" section in AGENTS.md before trusting a green run from it.

Five test targets: `AbbeyCoreTests`, `AbbeyCLITests`, `AbbeyServerKitTests`, `AbbeyServerTests` (HTTP-level via `VaporTesting`), `AbbeyBotAppTests`. The first four are what Linux CI runs; `AbbeyBotAppTests` needs the desktop target and therefore macOS + Xcode.

```bash
swift test --filter AbbeyCoreTests
swift test --filter AbbeyCoreTests.SomeTestCase/testSomeName

# Non-desktop targets without dragging in SwiftUI/SwiftData (also what CI/Docker/swiftly do):
ABBEY_PACKAGE_ROLE=server swift test --filter 'AbbeyCoreTests|AbbeyCLITests|AbbeyServerKitTests|AbbeyServerTests'
```

`ABBEY_PACKAGE_ROLE=server` is read in `Package.swift` and *omits the `AbbeyBotApp` target entirely* — it's required for any build that can't link AppKit, and it changes which targets exist rather than just which ones run. Don't pipe build/test output straight into `tail`: that masks the exit code, and a manifest or link failure then reads as success.

Run wrappers (load `.env` where relevant):

```bash
bash Scripts/run.sh          # desktop
bash Scripts/run-server.sh   # server
bash Scripts/run-abbey.sh    # abbey CLI
bash Scripts/swift-run.sh [serve|cli|…]   # raw SPM-style launch with checkout-safe build path
```

Dashboard SPA (`web/`, bun + Vite + React 19 + Biome + Vitest):

```bash
cd web
bun install
bun run lint      # biome check .
bun run test       # vitest run
bun run test path/to/file.test.tsx   # single test file
bun run build      # tsc -b && vite build → packed into Sources/AbbeyServer/Resources/Public/ for SPM
```

Optional Browserbase Functions (`functions/`, bun — not in verify-all): `cd functions && cp .env.example .env` then `bun run dev` / `bun run deploy`. See `functions/README.md`.

**Gate of record:** see [`AGENTS.md` → Verify](./AGENTS.md#verify) —
`verify-all.sh`, narrow smokes, and hosted Linux CI as commit-specific secondary
evidence. The disabled desktop job still requires a suitable macOS 27 runner.

## Architecture

**Persistence split:** desktop uses SwiftData directly; server and CLI share `AbbeyServerKit`'s Fluent engine (`BotRuntime`) but keep **separate databases** — CLI defaults to local SQLite at `~/.abbey/abbey.sqlite` and only shares the server's Postgres/`DATABASE_URL` when `ABBEY_CLI_USE_SERVER_DATABASE=1` is set. Desktop optionally push/pulls against the server's `/api/state/*` (best-effort; last-write-wins for users/channels/equity, insert-if-missing elsewhere; never blocks local writes).

**Persona routing:** three personas (`AbbeyPersona`, `AvivaPersona`, `AbiPersona` in `Sources/AbbeyCore/Personas/`) are prompt/register variants of one model, not separate systems. `ABIRouter.route(intent:)` picks a persona per message (mod/command → Abi, question → Aviva, greeting/small talk → Abbey). `DQNAgent` dispatches a four-wide answer/clarify/retrieve/refuse strategy head and learns from an immediate action-conditioned heuristic reward as a terminal contextual bandit; it does not yet learn from delayed user reactions and never overrides safety constraints. Switch paths: Discord `/persona`, natural-language intent, desktop Personas tab.

**Config gating:** `AppConfig.validateForStartup(scope:)` differs by entry point — `.desktop` enforces a live-Discord token unless dry-run; `.headless` (server/CLI) skips that UserDefaults-based Discord gate. HTTP may boot without `ABBEY_API_TOKEN`, but the operator root and grouped operator/state/sync/ingest/catalog `/api` routes then fail closed with 503; configured servers return 401 to missing/wrong Bearer or `X-Abbey-Token` callers. Health/static and separately signed native webhooks retain their own policies. `ABBEY_DRY_RUN=1` makes Discord/Twitch bridges skip sockets entirely.

**Learning state on disk** (all under `~/.abbey/`): `dqn-checkpoint.json` (+ `.bak`) via `DQNCheckpointStore`, append-only `dqn-experience.jsonl` via `ExperienceJournal`, and `rollback/<name>/` snapshots via `RollbackStore`. `CodeProposalValidator` is a static pattern-reject (shell/process/dlopen/network/rm) — **not** a sandbox; there is no isolated code-execution path yet.

**Sync cursor protocol:** desktop and CLI persist independent compound `(changedAt, stable ID)` cursors for all six entity streams. Incremental list requests use `since` + `after`; raw JSON-array responses publish the exact last-row boundary in `X-Abbey-Sync-Cursor-Time` / `X-Abbey-Sync-Cursor-ID`. Full pages advance only to that boundary, short pages advance through pull start, and legacy shared timestamps migrate automatically. Plain HTTP sync is accepted only for exact loopback hosts; remote sync requires HTTPS. This closes 500-row truncation and identical-timestamp loss. Remaining caveat: pull-start guards and LWW compare wall clocks, so significant desktop/server clock skew can still drop rows.

**Build path note:** SwiftPM build dirs are redirected under `${TMPDIR}/AbbeyBot*.build` (see the run scripts) to keep build output outside the checkout and avoid extended-attribute codesign failures — don't expect `.build/` at the repo root to be authoritative.

## Guardrails specific to this repo

- Don't port claims from `research_mlai.md` (Python/TensorFlow stack, WDBX throughput numbers, blockchain, HIPAA/GDPR, industry pilots) into product docs or code comments as if shipped — see AGENTS.md's "Not shipped" list.
- `IndustryProfile`, `WDBXMemoryFacade`, and `DecentralizationPolicy` (`Sources/AbbeyCore/{Industry,WDBX,Decentralization}/`) are deliberate **claim-honest shells** — a prompt-suffix flag, a local journal facade, and a policy stub that must stay disabled. Don't extend them to imply HIPAA/GDPR certification, real Zig-abi WDBX throughput, or an actual blockchain node; that's exactly the drift AGENTS.md's "Not shipped" list exists to prevent.
- Twitch: IRC PRIVMSG→ingest and persona reply (with cooldown) are shipped; IRC and EventSub chat share `BotRuntime.handleTwitchChat`. EventSub: `POST /api/twitch/eventsub` verifies HMAC-SHA256 + 10-min replay window when `TWITCH_EVENTSUB_SECRET` is set; duplicates by `Twitch-Eventsub-Message-Id` are acked without reprocessing (`TwitchEventSubReplayGuard`, backed by a Fluent `twitch_eventsub_deliveries` table — survives restarts, not in-process memory); `channel.chat.message` notifications ingest + persona-reply; `stream.online`/`stream.offline` update `twitchStreamLive` (on `/api/status`) + event bus + interaction log; follow/subscribe/cheer log interactions and soft-ingest social context (`BotRuntime.handleTwitchChannelSocial`); auto-subscribe on boot ships env-gated for all six notification types (`ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE=1` + full `TWITCH_*` contract, `TwitchEventSubAutoSubscriber`, off by default, unverified live). **Not shipped:** PubSub (won't ship — Twitch deprecated it), live-verified Helix handshake (needs a real public HTTPS callback this environment doesn't have).
- No CRDT merge (won't ship) — desktop and CLI pull with persisted per-entity compound cursors, LWW by `updatedAt`/`generatedAt`, and all-six-entity tombstones; 500-row pages drain via the server-issued timestamp + stable-ID boundary. CLI push remains messages + memory facts only. `/sync` stays a read-only status report. Codegen sandbox is a won't-ship (static `CodeProposalValidator` only).
- Discord Voice **audio** and **video/Go Live** are **in progress, not shipped** — voice presence (`/voice join|leave`) is the only verified runtime claim. A voice stack is landing in `Sources/AbbeyCore/Discord/` (Voice Gateway v8 client/state machine, UDP discovery) per `docs/discord-voice-architecture.md`, but don't claim audio or video until the live-call evidence in `tasks/goals.md` exists; that file plus `tasks/todo.md` are the completion ledger.

<!-- machine-git-policy -->
## Git workflow (machine policy, 2026-08-27)

This repo keeps its documented review-branch flow: changes route through
`codex/*`/`cursor/*` branches into `main`; never push directly to `main`.
That flow is the exception this machine's policy allows. Everything else
still applies: a review branch and any worktree for it must be merged into
`main` in this canonical checkout, the worktree removed, and the branch
deleted once merged, before the task is called done. Do not create extra
branches or worktrees beyond that flow. Full policy: `~/.claude/CLAUDE.md`
(*Git discipline*).
<!-- /machine-git-policy -->
