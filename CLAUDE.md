# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Full agent instructions (ops, personas, safety policy, deferred features) live in [`AGENTS.md`](./AGENTS.md) — **read that file before making non-trivial changes.** This file is a quick-reference layer on top of it.

Cursor uses a parallel persona at [`.cursor/agents/abbey.md`](./.cursor/agents/abbey.md) that mirrors AGENTS.md's verify gates, shipped/won't-ship lists, and toolchain rules — when those change here, update it too so the two don't drift.

All three products route through `AbbeyEntry` (the package's sole `@main`), which dispatches on the first argument (`serve` / `cli` / nothing → desktop).

## Commands

Always `unset TOOLCHAINS` first — desktop needs Xcode's toolchain, not a swiftly DEVELOPMENT-SNAPSHOT (breaks SwiftData `@Query` macros).

```bash
bash Scripts/verify-all.sh         # full gate — run before calling anything done
bash Scripts/run-smoke.sh          # desktop build/test/launch
bash Scripts/run-server-smoke.sh   # AbbeyServer + Postgres (compose) or sqlite fallback + GET /health
bash Scripts/run-cli-smoke.sh      # abbey CLI boot + DATABASE_URL isolation
```

Five test targets: `AbbeyCoreTests`, `AbbeyCLITests`, `AbbeyServerKitTests`, `AbbeyServerTests` (HTTP-level via `VaporTesting`), `AbbeyBotAppTests`. The first three are what Linux CI runs; `AbbeyBotAppTests` needs the desktop target and therefore macOS + Xcode.

```bash
swift test --filter AbbeyCoreTests
swift test --filter AbbeyCoreTests.SomeTestCase/testSomeName

# Non-desktop targets without dragging in SwiftUI/SwiftData (also what CI/Docker/swiftly do):
ABBEY_PACKAGE_ROLE=server swift test --filter 'AbbeyCoreTests|AbbeyCLITests|AbbeyServerKitTests'
```

`ABBEY_PACKAGE_ROLE=server` is read in `Package.swift` and *omits the `AbbeyBotApp` target entirely* — it's required for any build that can't link AppKit, and it changes which targets exist rather than just which ones run. Don't pipe build/test output straight into `tail`: that masks the exit code, and a manifest or link failure then reads as success.

Run wrappers (load `.env` where relevant):

```bash
bash Scripts/run.sh          # desktop
bash Scripts/run-server.sh   # server
bash Scripts/run-abbey.sh    # abbey CLI
bash Scripts/swift-run.sh [serve|cli|…]   # raw SPM-style launch, Desktop-safe build path (prefer over bare `swift run` under Desktop/iCloud)
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

**Gate of record:** see [`AGENTS.md` → Verify](./AGENTS.md#verify) — `verify-all.sh`, narrow smokes, CI secondary until billing unblocked.

## Architecture

**Persistence split:** desktop uses SwiftData directly; server and CLI share `AbbeyServerKit`'s Fluent engine (`BotRuntime`) but keep **separate databases** — CLI defaults to local SQLite at `~/.abbey/abbey.sqlite` and only shares the server's Postgres/`DATABASE_URL` when `ABBEY_CLI_USE_SERVER_DATABASE=1` is set. Desktop optionally push/pulls against the server's `/api/state/*` (best-effort; last-write-wins for users/channels/equity, insert-if-missing elsewhere; never blocks local writes).

**Persona routing:** three personas (`AbbeyPersona`, `AvivaPersona`, `AbiPersona` in `Sources/AbbeyCore/Personas/`) are prompt/register variants of one model, not separate systems. `ABIRouter.route(intent:)` picks a persona per message (mod/command → Abi, question → Aviva, greeting/small talk → Abbey); `DQNAgent` journals a 3-wide strategy index for display but does not yet dispatch answer/clarify/retrieve/refuse (see AGENTS.md open gap) and never overrides safety constraints. Switch paths: Discord `/persona`, natural-language intent, desktop Personas tab.

**Config gating:** `AppConfig.validateForStartup(scope:)` differs by entry point — `.desktop` enforces a live-Discord token unless dry-run; `.headless` (server/CLI) skips that UserDefaults-based gate so HTTP can boot without a token. `ABBEY_DRY_RUN=1` makes Discord/Twitch bridges skip sockets entirely.

**Learning state on disk** (all under `~/.abbey/`): `dqn-checkpoint.json` (+ `.bak`) via `DQNCheckpointStore`, append-only `dqn-experience.jsonl` via `ExperienceJournal`, and `rollback/<name>/` snapshots via `RollbackStore`. `CodeProposalValidator` is a static pattern-reject (shell/process/dlopen/network/rm) — **not** a sandbox; there is no isolated code-execution path yet.

**Sync cursor protocol:** desktop and CLI persist independent compound `(changedAt, stable ID)` cursors for all six entity streams. Incremental list requests use `since` + `after`; raw JSON-array responses publish the exact last-row boundary in `X-Abbey-Sync-Cursor-Time` / `X-Abbey-Sync-Cursor-ID`. Full pages advance only to that boundary, short pages advance through pull start, and legacy shared timestamps migrate automatically. This closes 500-row truncation and identical-timestamp loss. Remaining caveat: pull-start guards and LWW compare wall clocks, so significant desktop/server clock skew can still drop rows.

**Build path note:** SwiftPM build dirs are redirected under `${TMPDIR}/AbbeyBot*.build` (see the run scripts) to avoid codesign failures from Desktop/iCloud extended attributes — don't expect `.build/` at the repo root to be authoritative.

## Guardrails specific to this repo

- Don't port claims from `research_mlai.md` (Python/TensorFlow stack, WDBX throughput numbers, blockchain, HIPAA/GDPR, industry pilots) into product docs or code comments as if shipped — see AGENTS.md's "Not shipped" list.
- `IndustryProfile`, `WDBXMemoryFacade`, and `DecentralizationPolicy` (`Sources/AbbeyCore/{Industry,WDBX,Decentralization}/`) are deliberate **claim-honest shells** — a prompt-suffix flag, a local journal facade, and a policy stub that must stay disabled. Don't extend them to imply HIPAA/GDPR certification, real Zig-abi WDBX throughput, or an actual blockchain node; that's exactly the drift AGENTS.md's "Not shipped" list exists to prevent.
- Twitch: IRC PRIVMSG→ingest and persona reply (with cooldown) are shipped; IRC and EventSub chat share `BotRuntime.handleTwitchChat`. EventSub: `POST /api/twitch/eventsub` verifies HMAC-SHA256 + 10-min replay window when `TWITCH_EVENTSUB_SECRET` is set; duplicates by `Twitch-Eventsub-Message-Id` are acked without reprocessing (`TwitchEventSubReplayGuard`); `channel.chat.message` notifications ingest + persona-reply; `stream.online`/`stream.offline` update `twitchStreamLive` (on `/api/status`) + event bus + interaction log; follow/subscribe/cheer stay typed-ack + log only; auto-subscribe on boot ships env-gated for chat + stream lifecycle (`ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE=1` + full `TWITCH_*` contract, `TwitchEventSubAutoSubscriber`, off by default, unverified live). **Not shipped:** PubSub (won't ship — Twitch deprecated it), live-verified Helix handshake, side-effects for follow/subscribe/cheer and other non-stream/non-chat types.
- No CRDT merge (won't ship) — desktop and CLI pull with persisted per-entity compound cursors, LWW by `updatedAt`/`generatedAt`, and all-six-entity tombstones; 500-row pages drain via the server-issued timestamp + stable-ID boundary. CLI push remains messages + memory facts only. `/sync` stays a read-only status report. Codegen sandbox and Discord Voice **audio** are won't-ships (static `CodeProposalValidator` + voice presence only).
