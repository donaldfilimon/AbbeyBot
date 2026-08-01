# Todo

Granular steps under `tasks/goals.md`. Coarse intentions live there, not here.

## Harden Twitch EventSub retry semantics and webhook ack model

- [x] #1 Self-echo mislabeled as a delivery replay — `handleTwitchChat` returns
      `MessageIngestOutcome?`; route maps `nil` → `acknowledged("self-message")`.
- [x] #2 Retried delivery duplicated audit rows — ingest (dedup key) runs first, audit only on
      `.inserted`; `handleTwitchStreamLifecycle` reverted to non-throwing (its only durable state
      is an idempotent in-memory flag, so a retry could recover nothing and only append rows).
- [x] #3/#5 Missing ack model — `WebhookAckDTO` with `.handled` / `.acknowledged` / `.duplicate` /
      `forIngest`, shared by `TwitchEventSubRoutes` and `SocialRoutes`.
- [x] #4 Fragile claim/release — processing extracted to `TwitchEventSubRoutes.apply`; the
      `do/catch` is 3 lines with release adjacent to the single failing call.
      Closed as-is: a `withClaim` wrapper would only wrap that same do/catch, which is the thin
      pass-through indirection the review itself argued against. `release(_:)` must stay `public`
      (cross-module: AbbeyServerKit → AbbeyServer), so it cannot be narrowed either.
- [x] Coverage for the seam introduced: 3 route-level tests pinning the ack wire shape
      (`stream-online` handled, unacted notification acknowledged-not-duplicate, replay duplicate).
- [x] #6 Extract the three Twitch handlers into `BotRuntime+Twitch.swift`. Completed in the shared
      checkout at 00:29 while another session was reviewing the same runtime.
      `BotRuntime.swift` 935 → 819; new file 122 lines; `craftReply` and `twitchStreamLive` widened
      as predicted; all #1/#2 semantics preserved verbatim. Verified here, not authored here.

### Reopened scope (2026-08-01 00:36)

Goal moved `done` → `in_progress`. The six review findings above stay closed; these four are new
scope, not leftovers from them. Feasibility differs sharply — do not treat them as one batch.

- [~] **(in flight, agent 1)** **Persist the `TwitchEventSubReplayGuard`.** Today it is in-memory and process-lifetime
      (`static let` on `TwitchEventSubRoutes`), so a restart or a second instance reprocesses
      deliveries a previous ack already claimed as duplicates. Achievable here: back it with a
      Fluent table keyed on message id + received-at, prune on the existing 10-min replay window.
      Note the interaction with `release(_:)` — a released claim must not be resurrected by the
      persisted row.
- [~] **(in flight, agent 2)** **Real side-effects for follow / subscribe / cheer.** AGENTS.md currently lists these as
      typed-ack + log only; `handleTwitchChannelSocial` writes a soft memory note and an audit row.
      Achievable here, but it changes a documented "Not shipped" claim — AGENTS.md and README must
      move in the same commit, or the docs start lying.
- [ ] **Live Helix / EventSub handshake.** *Not achievable in this environment.* The
      `webhook_callback_verification` handshake needs a public HTTPS callback this box does not
      have, which is exactly why AGENTS.md has carried it as deferred. What can be done here is
      everything up to the network boundary; the verification itself needs a tunnel or a deployed
      host. Do not mark this done off a green local test.
- [ ] **Commit / push / open the PR.** Blocked, not merely pending: the working tree holds this
      session's changes interleaved with the other session's sync-cursor work (47 dirty files at
      00:34), and `git status` cannot separate them. Needs the other session to commit its own work
      first, or an explicit decision to land both together under one authorship.

## Retire the legacy sync-cursor policy layer

Do #1 first — it is the only finding with a correctness consequence (misleading coverage).
Everything here is in files a second session owns; re-check writer state before editing.

- [ ] **#1 Delete the duplicated policy and fix the coverage inversion.**
      - Delete `IncrementalSyncCursor.next(previous:attemptStartedAt:limit:pages:)` and the
        `IncrementalSyncCursor.Page` struct — zero production callers; all seven live sites
        (`SyncPull.swift` ×6, `CLISyncPull.swift` ×1) use the compound overload.
      - Delete the 5 legacy-only tests: `shortPagesAdvanceThroughPullStart`,
        `fullPageAdvancesOnlyThroughNewestReturnedChange`, `saturatedEndpointHoldsBackSharedCursor`,
        `missingTimestampOnFullPageRetainsPreviousCursor`,
        `serverClockAheadCannotAdvancePastPullStart`.
      - **Port the two genuine edge cases to the compound overload**, which currently has neither:
        server clock ahead of pull start (`guard serverBoundary.changedAt <= attemptStartedAt`) and
        full page with no boundary (`guard let serverBoundary else { return previous }`).
      - Note when deleting: `saturatedEndpointHoldsBackSharedCursor` asserts cross-entity `min()` —
        the shared-cursor behavior the new design *deliberately* replaced with independent
        advancement. It is a passing test pinning a policy that was intentionally abandoned.
- [ ] **#2 Collapse `SyncPullCursorSet` to `[SyncPullEntity: SyncPullCursor]`.**
      Six optional fields + six-case getter switch + six-case setter switch + six-arg init +
      six-field `legacyTimestamp` init ≈ 50 lines for one dictionary. A seventh entity means
      editing five places, and missing the setter case fails silently. `SyncPullEntity` is already
      `String`-raw + `CaseIterable`, so `Codable` comes free and `legacyTimestamp` becomes
      `Dictionary(uniqueKeysWithValues: SyncPullEntity.allCases.map { ($0, cursor) })`.
      **Scope note:** looping the six `next` call sites in `SyncPull.swift:98-121` is NOT part of
      this — the six streams have different row types, so a loop still enumerates six
      `(count, boundary)` entries and adds a force-unwrap. The struct is the whole win.
- [ ] **#3 Comment only, no code change.** A short page returns
      `SyncPullCursor(changedAt: attemptStartedAt)` with `stableID: nil`, which by the type's own
      doc comment degrades that stream to strict `timestamp > since`. This is acceptable —
      `attemptStartedAt` is a client wall-clock, so colliding exactly with a row's `changedAt` is
      far less likely than the row-to-row collision the feature exists to fix. Write that down so
      the next reader does not "fix" it.
- Considered and rejected as a finding: backward client clock moving the cursor back. Causes a
  refetch, not row loss.

## Verification residuals

All five test targets are verified against the final Swift 6.4 tree, including the compound
`SyncPullCursor` work and the extracted Twitch runtime.

- [x] Non-desktop targets: 221 tests green, exit 0 (77 core + 30 CLI + 94 server kit + 20 routes).
- [x] Desktop target: build clean + `AbbeyBotAppTests` 32 tests green, exit 0.
- [x] `Scripts/run-server-smoke.sh` green (sqlite-file; Docker unavailable).
- [x] `Scripts/run-cli-smoke.sh` green (boot, sync status/pull/push unconfigured, DATABASE_URL
      isolation).
- [x] `Scripts/verify-all.sh` run end-to-end: debug + release builds, 77 core tests, desktop
      `LAUNCH_OK`, server smoke, CLI smoke, and terminal `VERIFY-ALL GREEN`; exit 0.

### Transient failure worth recording

A desktop build at 00:22 failed with `generic parameter 'U' could not be inferred` at
`routes.swift:362,373` — inside the concurrent writer's brand-new `SyncPullCursor` boundary code,
not this work. They fixed it at 00:22:40 and the next build was clean. Recorded because a tree
shared by two agents will produce failures attributable to neither one's last change; check
`git diff` ownership and file mtimes before chasing one.
