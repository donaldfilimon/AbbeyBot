# Goals

## Harden Twitch EventSub retry semantics and webhook ack model
status: in_progress
- 2026-08-01: Fixed the four blocking code-review findings on `cursor/discord-fm-full-features`.
  Self-echo no longer reports as a delivery replay (`handleTwitchChat` returns
  `MessageIngestOutcome?`); retried deliveries no longer duplicate audit rows (ingest carries the
  dedup key and runs first, audit only on `.inserted`); `WebhookAckDTO` now owns the ack mapping
  shared by the Twitch and social routes, replacing a 3-variable × 8-case assignment matrix.
  `TwitchEventSubRoutes.swift` 190 → 168 lines while gaining a function.
- Gate: **253 tests green, exit 0** across all five targets — 221 non-desktop
  (77 AbbeyCoreTests + 30 AbbeyCLITests + 94 AbbeyServerKitTests + 20 AbbeyServerTests) and
  32 AbbeyBotAppTests.
  4 new tests, 3 of them driving the restructured route dispatch end-to-end.
  Re-verified at 00:25 against the tree *including* the concurrent writer's new `SyncPullCursor`
  code, so the green is current, not stale.
- 2026-08-01 00:29: **#6 closed in the shared checkout.** While another session was reviewing
  `BotRuntime.swift`, this session completed the extraction:
  created `Sources/AbbeyServerKit/BotRuntime+Twitch.swift` (122 lines), widened `craftReply` from
  `private` to internal and `twitchStreamLive` from `private(set)` to `internal(set)` — the exact
  two access changes this session had identified as prerequisites. `BotRuntime.swift` 935 → **819**.
  The extraction preserved every semantic from #1/#2 verbatim (`MessageIngestOutcome?` self-echo,
  ingest-first with audit-only-on-`.inserted`, non-throwing stream lifecycle, `twitchIngestKey`);
  it renamed `auditEvent` → `auditTwitchEvent`, which is an improvement in the Twitch-scoped file.
  The result was then verified across every product surface.
- Final gate after the extraction: `Scripts/verify-all.sh` exited 0 with debug + release builds,
  77 AbbeyCoreTests, desktop `LAUNCH_OK`, server smoke, CLI smoke, and terminal
  `VERIFY-ALL GREEN`. A separate all-target run passed all 253 tests, followed by a fresh
  production build of the final compound-cursor route snapshot.
- Re-verified 00:35: **252 tests green, exit 0** (220 non-desktop + 32 desktop). The count grew
  because the other session added its own sync tests (`ServerSyncApplyTests`,
  `IncrementalSyncCursorTests`, `SyncCursorStoreTests`, `SyncQueryTests`) — not because anything
  here changed. All structural claims above still hold exactly: `BotRuntime.swift` 819,
  `BotRuntime+Twitch.swift` 122, `TwitchEventSubRoutes.swift` 168, `WebhookAckDTO.swift` 39.
- 2026-08-01 00:36: **Reopened `done` → `in_progress` for new scope** (four items, detailed in
  `tasks/todo.md`): persist the replay guard, real side-effects for follow/subscribe/cheer, the
  live Helix/EventSub handshake, and landing this as a PR. The six original review findings stay
  closed — this is new scope, not leftovers. Two caveats recorded up front: the live handshake
  **cannot** be verified in this environment (no public HTTPS callback — the same reason AGENTS.md
  has carried it as deferred), and the PR is blocked on the shared working tree.
- Not committed. Restore point `a56adead` (`git stash create`; working tree untouched).

## Retire the legacy sync-cursor policy layer
status: todo
- Captured 2026-08-01 00:43 from a strict code-quality review of the compound-cursor work.
- **The new model is right** — compound `(changedAt, stableID)` cursors genuinely close the
  500-row truncation and identical-timestamp gaps. This goal is only about removing the *old*
  policy left standing beside it, not about relitigating the design.
- Core problem: `IncrementalSyncCursor` now encodes one policy twice. The legacy
  `next(previous:attemptStartedAt:limit:pages:)` overload and its `Page` struct have **zero
  production callers** (all seven live call sites use the compound form) yet own **5 of the 9
  tests** in `IncrementalSyncCursorTests.swift`. The two copies have already drifted, and the
  legacy tests create a coverage inversion — they exercise clock-skew and missing-boundary
  handling on the dead path while the compound equivalents that actually run are untested.
- Steps in `tasks/todo.md`. Priority: finding #1, then #2; #3 is a comment, not a code change.
- Not started: fixes are held while two dispatched agents and a second session are writing this
  tree. Editing `SyncPull.swift` with three live writers is how work gets lost.

## Align CLAUDE.md with what the build actually requires
status: done
- 2026-08-01: Added the five test targets and which three Linux CI runs, the
  `ABBEY_PACKAGE_ROLE=server` requirement (it *omits* the desktop target, per `Package.swift:7`),
  the `?since=` truncation gap with its named fix path, and a warning against piping build output
  through `tail` (which masks the exit code and reports failures as green).
