# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Full agent instructions (ops, personas, safety policy, deferred features) live in [`AGENTS.md`](./AGENTS.md) — **read that file before making non-trivial changes.** This file is a quick-reference layer on top of it.

## What this is

AbbeyBot: one SwiftPM package, **three products, one shared brain**, macOS 27 / Swift 6.4 language mode.

- **Desktop** — `AbbeyBotApp` (SwiftUI + SwiftData), launched by bare `swift run`.
- **Server** — `AbbeyServer` (Vapor + Fluent/Postgres, Leaf status page, `/api/*`, `/dashboard` React SPA), launched by `swift run AbbeyBot serve`.
- **CLI** — `abbey` (`AbbeyCLI`, terminal REPL, local SQLite), launched by `swift run AbbeyBot cli`.

All three route through `AbbeyEntry` (the package's sole `@main`), which dispatches on the first argument (`serve` / `cli` / nothing → desktop).

## Commands

Always `unset TOOLCHAINS` first — desktop needs Xcode's toolchain, not a swiftly DEVELOPMENT-SNAPSHOT (breaks SwiftData `@Query` macros).

```bash
bash Scripts/verify-all.sh         # full gate — run before calling anything done
bash Scripts/run-smoke.sh          # desktop build/test/launch
bash Scripts/run-server-smoke.sh   # AbbeyServer + Postgres (compose) or sqlite fallback + GET /health
bash Scripts/run-cli-smoke.sh      # abbey CLI boot + DATABASE_URL isolation
```

Single Swift test target/case:

```bash
swift test --filter AbbeyCoreTests
swift test --filter AbbeyCoreTests.SomeTestCase/testSomeName
```

Run wrappers (load `.env` where relevant):

```bash
bash Scripts/run.sh          # desktop
bash Scripts/run-server.sh   # server
bash Scripts/run-abbey.sh    # abbey CLI
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

**`bash Scripts/verify-all.sh` is the gate of record**, not GitHub Actions — hosted workflows on this private repo currently fail at startup (0 jobs) pending Actions billing/quota. Re-run `abbey-ci` once that's unblocked.

## Architecture

```
Sources/AbbeyCore/      shared brain: personas, inference, DiscordBM bridge, DQN, IntentClassifier — no SwiftData
Sources/AbbeyServerKit/ Fluent-backed BotRuntime + Models + Persistence — shared by AbbeyServer and abbey CLI
Sources/AbbeyEntry/     sole @main; dispatches desktop | serve | cli
Sources/AbbeyBotApp/    SwiftUI + SwiftData desktop UI (Engine/Equity/Models/Views)
Sources/AbbeyServer/    Vapor HTTP + Leaf status page + Routes; serves web/'s built SPA
Sources/AbbeyCLI/       abbey terminal REPL
Tests/                  AbbeyCoreTests, AbbeyCLITests, AbbeyServerKitTests (desktop has no hosted CI — needs a macOS 27 host)
web/                    React 19 + Vite dashboard SPA, built into Sources/AbbeyServer/Resources/Public/
```

**Persistence split:** desktop uses SwiftData directly; server and CLI share `AbbeyServerKit`'s Fluent engine (`BotRuntime`) but keep **separate databases** — CLI defaults to local SQLite at `~/.abbey/abbey.sqlite` and only shares the server's Postgres/`DATABASE_URL` when `ABBEY_CLI_USE_SERVER_DATABASE=1` is set. Desktop optionally push/pulls against the server's `/api/state/*` (best-effort, server-wins on conflicts, never blocks local writes).

**Persona routing:** three personas (`AbbeyPersona`, `AvivaPersona`, `AbiPersona` in `Sources/AbbeyCore/Personas/`) are prompt/register variants of one model, not separate systems. `ABIRouter.route(intent:)` picks a persona per message (mod/command → Abi, question → Aviva, greeting/small talk → Abbey); `DQNAgent` only selects *strategy* among already-allowed actions and never overrides safety constraints. Switch paths: Discord `/persona`, natural-language intent, desktop Personas tab.

**Config gating:** `AppConfig.validateForStartup(scope:)` differs by entry point — `.desktop` enforces a live-Discord token unless dry-run; `.headless` (server/CLI) skips that UserDefaults-based gate so HTTP can boot without a token. `ABBEY_DRY_RUN=1` makes Discord/Twitch bridges skip sockets entirely.

**Learning state on disk** (all under `~/.abbey/`): `dqn-checkpoint.json` (+ `.bak`) via `DQNCheckpointStore`, append-only `dqn-experience.jsonl` via `ExperienceJournal`, and `rollback/<name>/` snapshots via `RollbackStore`. `CodeProposalValidator` is a static pattern-reject (shell/process/dlopen/network/rm) — **not** a sandbox; there is no isolated code-execution path yet.

**Build path note:** SwiftPM build dirs are redirected under `${TMPDIR}/AbbeyBot*.build` (see the run scripts) to avoid codesign failures from Desktop/iCloud extended attributes — don't expect `.build/` at the repo root to be authoritative.

## Guardrails specific to this repo

- Don't port claims from `research_mlai.md` (Python/TensorFlow stack, WDBX throughput numbers, blockchain, HIPAA/GDPR, industry pilots) into product docs or code comments as if shipped — see AGENTS.md's "Not shipped" list.
- Twitch support is IRC presence only (no EventSub, no chat→ingest loop); don't assume incoming Twitch messages reach the classifier.
- No CRDT merge or `?since=` cursor pagination for desktop↔server sync — it's push + pull with server-wins conflict resolution and a 500-row cap.
