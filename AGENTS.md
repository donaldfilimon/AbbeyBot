# AbbeyBot

Canonical instructions for the Swift checkout, not the separate Rust `abbey-bot` repository.

## Package Boundaries

- One Swift package and one executable product, `AbbeyBot`. `Sources/AbbeyEntry/main.swift` dispatches desktop (default), `serve`, `cli`, and `quasar serve`; `AbbeyServer` and `AbbeyCLI` are targets, not executable products.
- `AbbeyCore` owns shared inference, Discord, scoring, and sync contracts. Check both `AbbeyBotApp/AbbeyEngine.swift` (SwiftData) and `AbbeyServerKit/BotRuntime.swift` (Fluent, shared by server/CLI) when changing ingest or slash behavior.
- `AbbeyQuasarKit` owns site generation, approval, mutation, preview, and archives. Its HTTP surface has separate authorization in `Sources/AbbeyServer/Routes/QuasarRoutes.swift` and bind policy in `QuasarServePolicy.swift`.
- `Package.swift` selects targets from environment: `ABBEY_PACKAGE_ROLE=server` removes desktop/media-macOS targets; `ABBEY_NATIVE_MEDIA=1` adds native DAVE/Opus/libsodium dependencies. Ordinary builds must not require a native dependency prefix. Keep `ABBEY_HAS_DESKTOP`, not `canImport(AbbeyBotApp)`, for entry dispatch: stale scratch modules can fool `canImport`.

## Toolchain and Launch

- Swift tools 6.4, Swift language mode 6, macOS 27. Desktop requires Xcode; swiftly development snapshots break SwiftData macros. Never change the global swiftly default to fix this repo.
- Prefer wrappers below. For direct Swift commands, unset `TOOLCHAINS`, use `/usr/bin/xcrun --toolchain default swift`, and pass `--build-path "${TMPDIR:-/tmp}/AbbeyBot.build"` to avoid checkout extended-attribute/codesign failures.
- `.swift-version` is machine-local and ignored. An untracked `xcode` selector is appropriate on macOS; never commit it because that selector breaks Linux swiftly invocations.

```bash
bash Scripts/run.sh                # signed .app via LaunchServices
bash Scripts/swift-run.sh help     # AbbeyBot arguments, not SwiftPM flags; unsigned launch
bash Scripts/run-server.sh         # server graph; loads .env
bash Scripts/run-abbey.sh          # CLI graph; loads .env
```

- The CLI wrapper clears `DATABASE_URL` unless `ABBEY_CLI_USE_SERVER_DATABASE=1`; its default DB is `~/.abbey/abbey.sqlite`, separate from the server. Do not assume `.env` makes them share storage.
- Every `~/.abbey` default (DQN checkpoint and experience journal, WDBX, rollback, pending pushes, CLI DB and sync cursors) resolves through `AbbeyCore/Engine/AbbeyDataDirectory.swift`: `ABBEY_DATA_DIR` if set, a per-process temp directory inside a test host, else `~/.abbey`. Never add a new `homeDirectoryForCurrentUser` + `.abbey` path; tests must never write the operator's real learning data. `HOME` does not redirect it (`homeDirectoryForCurrentUser` ignores it).
- App Sandbox must stay disabled until the `~/.abbey` migration is resolved; `Scripts/run-smoke.sh` explicitly checks this. Hardened Runtime and capture entitlements are separate concerns.

## Verify

Run from the repository root. `bash Scripts/verify-all.sh` is the ordinary-product release gate, in this order:

```bash
bash Scripts/check-static-security.sh
bash Scripts/check-package-graphs.sh
bash Scripts/check-knowledge-snapshot.sh
bash Scripts/run-web-smoke.sh
bash Scripts/run-smoke.sh
bash Scripts/run-server-smoke.sh
bash Scripts/run-cli-smoke.sh
```

- Use the relevant smoke during iteration; run `verify-all.sh` before shipping a cross-surface change. Continuation requests include the scoped gate and requested ship steps, not just an intermediate green. Static/security failures must pass or have an explicitly accepted exception.
- Desktop smoke builds debug and release, runs all ordinary Swift tests, validates signing/privacy metadata, and launches with media disabled. Native media is deliberately excluded. Package-graph checks inspect manifests, not native linking.
- Desktop smoke clears inherited `ABBEY_DRY_RUN` and `ABBEY_QUIET` for unit tests so injected lifecycle gateways run; its signed-app launch remains explicitly dry-run and media-disabled.
- Server smoke may start Compose Postgres and honor an inherited `DATABASE_URL`; without Docker it uses a temporary SQLite file. It preserves bot credentials and prints the DB URL. Use a disposable database and explicit `ABBEY_DRY_RUN=1` for non-live verification; do not assume all smokes isolate `HOME` or credentials. Each smoke and the knowledge check do create their own `ABBEY_DATA_DIR` and ignore an inherited one, so a gate run cannot touch `~/.abbey`. SQLite success is not Postgres evidence.
- Web smoke must precede Swift packaging: Vite empties and writes `Sources/AbbeyServer/Resources/Public/`, not `web/dist`. Standalone server smoke permits a missing dashboard as a skip.
- Knowledge smoke checks the signed bundled bytes with one test filter; unlike most wrappers it uses the default SwiftPM scratch directory. Do not hand-edit signed snapshot bytes to fix a failure; inspect `Scripts/refresh-knowledge-snapshot.swift`.

Focused Swift tests on macOS (replace the filter with a target, suite, or test):

```bash
unset TOOLCHAINS ABBEY_NATIVE_MEDIA ABBEY_NATIVE_PREFIX ABBEY_NATIVE_CACHE
ABBEY_PACKAGE_ROLE=server /usr/bin/xcrun --toolchain default swift test \
  --build-path "${TMPDIR:-/tmp}/AbbeyBot.server.build" \
  --filter 'AbbeyCoreTests.InteractionRouterGuardsTests/validatedForgetIndexAcceptsPositiveOneBased'
```

- For desktop tests, unset `ABBEY_PACKAGE_ROLE` and use the desktop scratch path. Server CI filters are Core, Quasar, CLI, ServerKit, and Server; only `AbbeyServerKitTests` receives `DATABASE_URL=sqlite://memory`. Desktop adds `AbbeyBotAppTests` and `AbbeyMediaMacOSTests`; native opt-in adds `AbbeyMediaNativeTests`.
- In `web/`: `bun install --frozen-lockfile`, `bun run lint` (Biome), `bun run test` (Vitest), `bun run build` (TypeScript then Vite). Single file: `bun run test src/path.test.tsx`. Use `bun run test`, not Bun's built-in `bun test`.
- `functions/` is a separate optional Browserbase Bun package, outside CI/verify-all; see `functions/README.md`. `bun run typecheck` is local; `bun run deploy` publishes externally.

### Additional Gates

- `bash Scripts/check-server-snapshot.sh`: native-host nightly build plus all five server test filters; selects a swiftly snapshot per invocation. Never use this toolchain for desktop.
- `bash Scripts/check-server-linux.sh`: matching pinned snapshot/Static Linux SDK, product-only cross-compile plus glibc-divergence lint. Read its header for setup. It targets musl, not CI's glibc, and cannot compile Testing/XCTest; it complements rather than replaces snapshot tests. Avoid C stdio globals in portable Swift; use `FileHandle.standardError`/`.standardOutput`.
- `bash Scripts/run-native-media-smoke.sh`: bootstraps isolated native dependencies and tests native debug/release paths. Ordinary `verify-all` clears native flags and does not cover this.
- `.github/workflows/abbey-ci.yml` builds web assets before the server graph in `swiftlang/swift:nightly-6.4.x-bookworm`. There is no desktop job. CI is commit-specific secondary evidence, not signed-app, native-media, Dockerfile deployment, or live-service proof.

## Behavioral Boundaries

- `ABBEY_API_TOKEN` is required for operator root/API routes: unset/blank returns 503; missing/wrong caller credentials return 401. Health, static dashboard, and native webhooks have separate policies. Full-server Quasar requires `ABBEY_QUASAR_API_TOKEN`; only explicitly governed Quasar-only loopback mode permits tokenless access. Do not merge these auth policies.
- Sync clients must share `Sources/AbbeyCore/Sync/` contracts: independent per-entity `(changedAt, stable ID)` cursors, server-issued boundaries/high-watermarks, LWW and tombstones. Preserve legacy cursor migration and failed-pull progress. CLI `/sync` is read-only; `/sync push` covers messages and facts only. Remote sync requires HTTPS; plain HTTP is exact-loopback only. CRDT merge is out of scope.
- Preserve Quasar's exact-plan approval, bounded path guard, single-writer registry, and rollback integrity checks. A successful scaffold or local preview is not live provider-backed generation or authorization to deploy.
- `Contracts/Abbey/` is vendored data also packaged by AbbeyCore. Preserve exact corpus identity and qualification tests; corpus conformance does not prove canonical-CBOR decoding or external service behavior.
- Discord audio and video/Go Live need separate participant-consented live evidence; local DAVE/codec/transport tests do not prove either shipped. Read `tasks/goals.md` and `tasks/todo.md` for acceptance evidence, checking dated observations against current code. Never persist/log voice credentials, transport keys, DAVE material, or raw captured media. Keep capture and recording behind explicit operator policy.
- `/validate` is a static reject-list, not a sandbox. Never silently execute generated code; do not scaffold a codegen sandbox in this package.
- Local WDBX/industry/decentralization shells are not the separate ABI runtime, certified compliance, or blockchain. Persona routing is not separate models; heuristic DQN rewards do not authorize safety bypasses or prove delayed-feedback learning.

## Workflow

- Use the canonical checkout. Changes land via `cursor/*` (preferred) or `codex/*` review branches and PRs into `main`; never commit/push directly or force-push `main`. These prefixes also control push CI. Avoid extra worktrees; remove only inactive, clean, fully merged worktrees/branches after integration.
- Keep `.env`, `.swift-version`, dependencies, `.cursor/hooks/`, build products, and generated SPA assets untracked. Static/security checks also reject untracked numbered duplicate Swift files such as `Thing 2.swift`.
- `.claude/skills/abbey-verify/SKILL.md` defines the ship workflow. `CLAUDE.md` points here. Gate/toolchain convention changes also affect `.cursor/agents/abbey.md`, `.codex/agents/abbey.toml`, and the `.claude`/`.agents` verification skill mirrors; check for drift when changing those conventions.
