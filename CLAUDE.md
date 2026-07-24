# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

AbbeyBot: one Swift 6.4 package, **two products** sharing one brain (`AbbeyCore`) — a macOS 27 SwiftUI desktop companion and a headless Vapor/Fluent Discord server. Targets `.macOS(.v27)`; Xcode toolchain only (swiftly DEVELOPMENT-SNAPSHOT breaks SwiftData macros).

| Product | Target | Persistence | Surface |
|---------|--------|-------|-----|
| Desktop | `AbbeyBot` (`AbbeyBotApp`) | SwiftData | SwiftUI |
| Server | `AbbeyServer` | Fluent + Postgres (sqlite for smoke) | Leaf status page + `/api/*` |

Shared: `AbbeyCore` — personas, inference routing, DiscordBM gateway/REST bridge, DQN reinforcement engine. No SwiftData dependency in `AbbeyCore` (keeps it usable from the server target too).

## Commands

Always via `xcrun --toolchain default` with `TOOLCHAINS` unset — plain `swift`/PATH toolchain breaks SwiftData macros and the WDBX-style network listeners.

```bash
unset TOOLCHAINS
bash Scripts/run-smoke.sh          # desktop: debug build, release build, AbbeyCoreTests, app launch check
bash Scripts/run-server-smoke.sh   # server: compose Postgres (or sqlite file fallback) + GET /health assertion
bash Scripts/run.sh                # launch desktop app
bash Scripts/run-server.sh         # launch server (loads .env if present)
```

Manual equivalents:

```bash
/usr/bin/xcrun --toolchain default swift build --build-path "${TMPDIR}/AbbeyBot.build"
/usr/bin/xcrun --toolchain default swift test --filter AbbeyCoreTests --build-path "${TMPDIR}/AbbeyBot.build"
/usr/bin/xcrun --toolchain default swift run AbbeyServer serve --hostname 0.0.0.0 --port 8080 --build-path "${TMPDIR}/AbbeyBot.server.build"
```

Always pass `--build-path "${TMPDIR}/..."` (or use the scripts, which do this) — building directly under `~/Desktop` hits iCloud/Finder xattr codesign failures. Note `--build-path` goes *before* the product name for `swift run`.

Single test: `swift test --filter AbbeyCoreTests/intentClassification --build-path "${TMPDIR}/AbbeyBot.build"` (test names come from `@Test func` in `Tests/AbbeyCoreTests/AbbeyCoreTests.swift`).

Server without Docker: `DATABASE_URL=sqlite://${TMPDIR}/abbey.sqlite ...` (or `sqlite://memory` for pure in-memory). With Docker: `docker compose up -d db` (Postgres 16) then run the server, or `docker compose up --build` for the full stack.

## Architecture: the mirrored-engine pattern

The desktop and server products are **not** thin wrappers around a shared engine object — each has its own top-level engine (`AbbeyBotApp/AbbeyEngine.swift` for desktop, `AbbeyServer/BotRuntime.swift` for server) that independently wires up the same set of `AbbeyCore` actors, then talks to a different persistence layer:

- Desktop `AbbeyEngine` (`@MainActor`, `@Observable`) → SwiftData `ModelContainer`, models in `AbbeyBotApp/Models/`.
- Server `BotRuntime` (`actor`) → Fluent `Database`, models in `AbbeyServer/Models/` + repositories in `AbbeyServer/Persistence/Repositories.swift`.

Both construct the identical stack of `AbbeyCore` actors — `EventBus`, `DQNAgent`, `ABIRouter` (persona), `InferenceRouter`, plus a scheduler and social-brain that are persistence-specific pairs: `AbbeyScheduler`/`SocialBrain` (SwiftData) vs `FluentScheduler`/`FluentSocialBrain` (Fluent, under `AbbeyServer/Persistence/`). When changing ingestion, persona routing, or scoring logic, **check whether the change needs to land in both `AbbeyEngine.ingestMessage`/`BotRuntime.ingestMessage` and both `makeMessageIngress`/`makeInteractionRouter` closures** — they are hand-mirrored, not shared code, and will silently diverge if only one is edited.

Message flow (both products): Discord gateway event → `DiscordBridge` (AbbeyCore) → `MessageIngress`/`InteractionRouter` closures built by the engine → `ingestMessage` (persist, classify intent via `IntentClassifier`, score via `IngestScorer` → `DQNAgent`, update reputation via the social-brain actor, publish to `EventBus`) → persona reply via `ABIRouter.currentPersona().respond(...)` → `InferenceRouter`.

**Inference fallback chain** (`AbbeyCore/Inference/InferenceProvider.swift`): `InferenceRouter` picks a provider per `AppConfig.inferenceMode` (`deterministicFloor` / `onDevice` / `remoteCompatible`) and on *any* failure falls through unconditionally to `DeterministicFloorProvider`, publishing `.inferenceProviderFailed` on the `EventBus` so the failure is observable rather than swallowed. Never let inference errors propagate past `InferenceRouter.generate` — the deterministic floor must always produce a result.

**Personas** (`AbbeyCore/Personas/`): `ABIRouter` is an actor holding the currently active persona (`AbbeyPersona`, `AvivaPersona`, `AbiPersona`), switchable via intent (`.modRequest`/`.command` → Aviva, `.greeting`/`.smallTalk` → Abi) or explicitly via `setPersona(named:)` / the `persona` slash command. It's constructed per-engine instance deliberately (not a `static var` singleton) so multiple engines (previews, tests) don't share persona state.

**Config**: `AppConfig.shared` (`AbbeyCore/AppConfig.swift`) is the single source for both products — `UserDefaults` for settings, Keychain (`TokenStore`, `Security` framework) for `DISCORD_BOT_TOKEN` on Apple platforms, falling back to `UserDefaults`/env off-Apple. The server also reads `DISCORD_BOT_TOKEN`/`DISCORD_DEV_GUILD_ID`/`DATABASE_URL` directly from `ProcessInfo.environment` (env takes precedence over `AppConfig`'s stored value there — see `BotRuntime.start()`).

**DQN scoring**: `IngestScorer.scoreAndLearn` projects message signals (sentiment, reputation, interaction/channel activity) to an 8-lane input via `SentimentAnalyzer.projectToNetworkInput`, feeds `DQNAgent` (topology `[8, 32, 16, 3]`), and the result nudges reputation through the social-brain actor (`ReputationMath`).

**Slash commands**: `ask`, `rep`, `remember`, `forget`, `context`, `persona` — registered via `CommandRegistry`, routed via `InteractionRouter` closures built in each engine's `makeInteractionRouter()`.

## Server specifics

`AbbeyServer/configure.swift` picks the Fluent driver from `DATABASE_URL` (`postgres://`/`postgresql://`, `sqlite://memory`/`sqlite::memory:`, or `sqlite://<path>`) and logs the resolved dialect. `BotLifecycleHandler` starts/stops `BotRuntime` on app boot/shutdown (async, no semaphore parking). Routes (`Routes/routes.swift`): `GET /health`, `GET /api/metrics`, `GET /api/status`, `POST /api/ingest`, `GET /api/users`, `GET /api/channels`, `GET /api/messages`, `GET /api/reputation`, `GET /api/interactions`, `GET /api/equity` (list endpoints support `?limit=`, default 100 / max 500), `GET /` (Leaf status page with dialect + table counts). Lifecycle uses Vapor `didBootAsync` / `shutdownAsync`. Deploy artifacts: `Dockerfile` (`swift:6.0-bookworm`), `docker-compose.yml`, `deploy/abbeybot.service`.

## Gotchas

- `swift-tools-version: 6.4`, Swift language mode `.v6` on every target — mind strict concurrency (actors, `Sendable`) when touching shared code.
- Build off `~/Desktop` (`--build-path "${TMPDIR}/..."`) or codesign fails on iCloud-synced xattrs.
- `unset TOOLCHAINS` before any `xcrun --toolchain default swift ...` invocation.
- Discord bot needs the **Message Content** intent enabled in the Developer Portal or ingestion silently receives nothing.
- Shared scoring/copy helpers live in AbbeyCore (`IngestScorer`, `ReputationMath`, `DiscordCopy`); engines are persistence adapters.
- Deferred/not yet shipped: React dashboard SPA, Discord Voice, SwiftData↔Postgres sync between the two products.
