# Todo

Granular steps under `tasks/goals.md`. Coarse intentions live there, not here.

## Release and SwiftData hardening — closed

- [x] Preserve released flat v2 sync cursor JSON and decode the transient enum-dictionary format;
      literal core, desktop `UserDefaults`, and CLI file-store fixtures are green.
- [x] Make Twitch replay-table migration compatible with fresh, older table-absent, and
      table-present databases; four-case SQLite upgrade/rollback matrix is green.
- [x] Require HTTPS for non-loopback sync endpoints and validate before attaching credentials or
      content; seven focused tests across core, desktop, and server/CLI clients are green.
- [x] Make Docker-published server/Postgres ports loopback-only by default.
- [x] Make the CLI smoke execute every asserted command, clear inherited sync configuration, and
      isolate per-run logs/databases; direct command protocol is green 50/50 and the wrapper passes
      with deliberately hostile inherited sync variables.
- [x] Make desktop memory, reputation, and equity side effects post-commit only. Four memory and
      three reputation failure/success tests are green; equity failures roll back and surface an
      operator-visible error without advancing generator state or publishing events.
- [x] Expand local/CI verification to static/security hygiene, dashboard lint/test/build, all four
      Linux server-side Swift bundles, all five local Swift bundles, and executable smokes.
- [x] Final combined `Scripts/verify-all.sh` green: static/security; dashboard lint + 17 tests +
      production build; all Swift tests including 47 desktop tests in 9 suites; desktop launch;
      server HTTP/database smoke (SQLite-file fallback because Docker/Postgres was unavailable);
      and hermetic CLI smoke.

## Harden Twitch EventSub retry semantics and webhook ack model — all closed

- [x] #1 Self-echo mislabeled as a delivery replay — `handleTwitchChat` returns
      `MessageIngestOutcome?`; route maps `nil` → `acknowledged("self-message")`.
- [x] #2 Retried delivery duplicated audit rows — ingest (dedup key) runs first, audit only on
      `.inserted`.
- [x] #3/#5 Missing ack model — `WebhookAckDTO` with `.handled` / `.acknowledged` / `.duplicate` /
      `forIngest`, shared by `TwitchEventSubRoutes` and `SocialRoutes`.
- [x] #4 Fragile claim/release — processing extracted to `TwitchEventSubRoutes.apply`; release
      adjacent to the single failing call. `release(_:)` stays `public` (cross-module).
- [x] #6 Extracted the three Twitch handlers into `BotRuntime+Twitch.swift`.
      `BotRuntime.swift` 935 → 819.
- [x] Persist the `TwitchEventSubReplayGuard` — Fluent-backed (`Models/TwitchEventSubDelivery.swift`),
      unique-constraint insert as the atomic claim, `release` hard-deletes for re-claimability,
      fail-closed on DB error.
- [x] **Migration follow-up fixed, twice.** First pass extracted the table creation into its own
      `AddTwitchEventSubDeliveries` migration; a concurrent session then took a different, also
      valid design — keep the table in `CreateAll` for fresh databases and let
      `AddTwitchEventSubDeliveries` use `.ignoreExisting()` to adopt it on already-migrated ones
      (mirrors how Fluent's own `MigrationLog` migration handles the same problem). That design is
      correct, but a *later* concurrent edit to the same file dropped `.ignoreExisting()` from the
      `.create()` chain while leaving the doc comment describing the old behavior — caught live via
      `swift test --filter TwitchEventSubMigrationUpgradeTests` (3 of 4 cases failing with
      `table already exists`) and `Scripts/run-server-smoke.sh` (boot failure on a fresh sqlite
      file). Restored `.ignoreExisting()`; both now green — see `tasks/goals.md` for the full
      timeline and the lesson about not trusting a quoted-from-memory green after further edits.
- [x] Real side-effects for follow / subscribe / cheer — `handleTwitchChannelSocial`'s `.inserted`
      branch publishes `AbbeyEvent.twitchChannelSocial` and credits `guildId=twitch` reputation via
      `FluentSocialBrain.recordInteraction` (EMA targets: follow 0.65, cheer 0.80, subscribe 0.90;
      anonymous cheers skip reputation). Idempotency verified by mutation test.
- [x] Doc-honesty fixes — AGENTS.md, CLAUDE.md updated where they said "typed-ack + log only" /
      "in-memory" replay guard; both were false against the shipped code.
- [x] Cross-session conflict audit — read-only investigation confirmed the replay-guard table and
      the ingest-key dedupe are a deliberate two-layer design, not competing implementations. One
      coverage gap noted for later: no test exercises both dedupe layers together.
- [ ] **Live Helix / EventSub handshake — not achievable in this environment**, permanently open
      until a public HTTPS callback exists. Do not mark done off a green local test.
- [x] **Published and merged through PR #53.** `codex/massive-improve-cleanup` was rebased on
      current `origin/main`, pushed, merged without a force-push, and deleted remotely. Local
      `main` was checked out and verified byte-for-byte at the resulting `origin/main` merge commit.

## Retire the legacy sync-cursor policy layer — all closed

- [x] **#1 Deleted the duplicated policy and fixed the coverage inversion.** Removed the dead
      `IncrementalSyncCursor.next(...pages:)` overload and `Page` struct (zero production callers);
      removed the 5 legacy-only tests; ported the two genuine edge cases (server-clock-ahead,
      missing-boundary-on-full-page) onto the compound overload's own test coverage.
- [x] **#2 Collapsed `SyncPullCursorSet` to `private var values: [SyncPullEntity: SyncPullCursor]`.**
      Public API (labeled init, `legacyTimestamp` init, subscript, `earliestChangedAt`) unchanged.
      The two real call sites (`SyncPull.swift`, `CLISyncPull.swift`) converted from named-property
      to subscript access — grepped the whole tree, no other call site needed the same fix.
- [x] **Persisted format compatibility repaired.** Custom dynamic-key `Codable` preserves the
      released flat v2 JSON and also decodes the transient synthesized enum-dictionary `values`
      representation. Literal fixtures pass through the core codec, desktop `UserDefaults`, and
      CLI file stores; flat keys win if both representations appear.
- [x] **#3 Comment added** on the short-page tie-breaker loss — corrected during writing for the
      `serverHighWatermark` mechanism the other session added concurrently, since the original
      "client wall-clock" justification no longer matched what the code actually does (the upper
      bound is now usually a server-issued timestamp, not a client one).
- Considered and rejected as a finding: backward client clock moving the cursor back. Causes a
  refetch, not row loss.

## Verification evidence

- [x] Non-desktop, re-verified after the `.ignoreExisting()` fix: 255 tests green, exit 0
      (21 AbbeyServerTests + 117 AbbeyServerKitTests + 87 AbbeyCoreTests + 30 AbbeyCLITests).
- [x] Desktop: build clean, 36 `AbbeyBotAppTests` green, exit 0 (last full `verify-all.sh` baseline;
      not re-run after the migration fix since desktop uses SwiftData, not Fluent, and touches none
      of the changed code).
- [x] `Scripts/run-server-smoke.sh` re-verified after the fix — `SERVER SMOKE GREEN`, exit 0,
      including the migration boot path against a fresh sqlite file.
- [x] `Scripts/run-cli-smoke.sh` green (last full `verify-all.sh` baseline).
- [x] `TwitchEventSubMigrationUpgradeTests` (4 cases: fresh bootstrap, forward-migrate-only,
      adopt-existing-table, revert-preserves-table) — 4/4 green after the fix; this is the suite
      that caught the regression in the first place.
- [x] Sync-cursor collapse re-verified independently by a dedicated build/test agent after landing:
      same 277-test result, both server-role and desktop builds exit 0.
- [x] Current cursor compatibility: 12 core cursor tests, 15 desktop cursor-store tests, and the
      CLI cursor file-store suite green.
- [x] Current dashboard: Biome, 4 Vitest files / 17 tests, production build, and packed-resource
      assertion green.
- [x] Current static/security hygiene gate green.
- [x] Updated `Scripts/verify-all.sh` green across static/security, dashboard, all five Swift test
      bundles, desktop launch, server smoke, and CLI smoke. This supersedes the historical partial
      and interrupted runs documented below.

### Institutional memory worth keeping

- A desktop build failed once with `generic parameter 'U' could not be inferred` inside another
  session's brand-new boundary code, mid-edit — not this work's fault. They fixed it ~40s later.
  Lesson: a tree shared by multiple concurrent agents will produce failures attributable to
  neither one's last change; check `git diff` ownership and file mtimes before chasing one.
- This checkout was, over roughly 90 minutes, edited concurrently by this session, subagents this
  session dispatched, and at least one separate AI coding tool (`cursor/*` and `codex/*` local
  branches). Branches and even the checked-out ref changed several times without this session's
  involvement, including a local merge into `main` that bypassed this repo's PR-only workflow.
  Full detail in `tasks/goals.md`'s "Branch state" section. Lesson for next time: re-verify
  `git rev-parse --abbrev-ref HEAD` before trusting any earlier assumption about which branch is
  live, especially after a background agent or tool-call gap.
