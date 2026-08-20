# Goals

## Complete Discord application and real Discord Voice audio
status: in_progress
- Gateway voice presence is shipped today; real Discord audio is not. Completion requires a
  confirmed main-gateway voice handshake, Voice Gateway v8, UDP discovery, mandatory transport
  AEAD, DAVE end-to-end encryption, RTP/Opus send and receive, capture/playback, reconnect/resume,
  operator UI and permission controls, deterministic integration tests, and a live DAVE-enabled
  guild-call validation.
- Treat Discord's March 1, 2026 DAVE-only call requirement as a release constraint. A
  transport-only RTP/Opus demonstration, a gateway presence update, or a mocked green test is not
  evidence that AbbeyBot can participate in a current Discord call.
- Keep voice credentials and media private: never persist or log the voice token, endpoint,
  session id, transport key, DAVE/MLS material, or raw microphone audio. Recording and
  transcription remain off by default and require an explicit operator/guild policy.
- Keep the existing text/slash application reliable while voice lands: main-gateway readiness and
  disconnect semantics, runtime command authorization, response error visibility, and connection
  observability are part of this goal rather than separate polish.
- Completion evidence must include protocol fixtures, local WebSocket/UDP and loss/reorder fault
  tests, Opus loopback, Apple audio-device/permission tests, the full repository gate, and a live
  join/speak/hear/reconnect/leave run using a rotated bot token in an authorized test guild.
- **Audit 2026-08-01 (read-only, against `2a423e1`):** 4 of 12 checklist items are genuinely
  shipped with tests (handshake accumulator, Voice Gateway v8 state machine, UDP discovery +
  protocol selection, RTPSIZE transport encryption — green inside the 234-test AbbeyCoreTests
  run). The rest are PARTIAL: well-built parts (pinned real-MLS libdave binding, libopus codec,
  RTP pieces, AVAudioEngine adapter, a fully-tested but *dead-code* reconnect client) that no
  production path composes — `nextAudioFrame()`, `sendProtectedPacket`, and transport encryption
  have no production callers, and nothing advertises nonzero DAVE (honestly). CI never sets
  `ABBEY_NATIVE_MEDIA=1` and has no macOS job, so none of the native/media suites run there.
  Live evidence (item 12) stays missing and is operator-blocked, not code-blocked. Full detail
  in `tasks/todo.md` → "Voice audit snapshot".
- **PR #55 validation 2026-08-03:** the isolated native gate was launched from a clean merged
  `433eb17` checkout and is green
  with pinned libdave 1.1.1, Opus 1.6.1, and libsodium 1.0.22: 37 tests in 6 suites passed in
  debug and again in release, both runtime-secrecy probes passed, and static/security passed.
  This is local component proof only. No live Discord probe ran because no bot token or dev-guild
  ID was available in the process, launch environment, repository env files, or AbbeyBot Keychain
  service. Concurrent uncommitted native edits appeared later, so this green is retained as the
  exact run result rather than claimed as an immutable byte-for-byte post-run checkout. More
  importantly, merged PR #55 intentionally exposes only a signaling/UDP probe that
  auto-leaves with "DAVE unavailable" and sends no media. The goal remains `in_progress`; exact
  operator steps and engineering residuals are recorded in `tasks/todo.md`.
- **PR #55 app-launch follow-up 2026-08-03:** an app packaged from isolated `origin/main` at
  `655ef0f` initially passed `codesign --verify` but failed before startup because Hardened Runtime
  rejected the ad-hoc-signed embedded `libdave.dylib`. `Scripts/build-macos-app.sh` now adds
  `com.apple.security.cs.disable-library-validation` only when an ad-hoc build actually embeds
  native code; named signing identities retain library validation. The rebuilt bundle passed deep
  strict signature verification, linked `@rpath/libdave.dylib`, and remained running for the
  launch probe. This closes an app-packaging prerequisite only. No Discord credentials were
  available and no live signaling, DAVE, audio, reconnect, or channel-move evidence was produced.
- **Post-PR #55 integration follow-up 2026-08-03:** active and replacement DAVE Commit candidates
  now remain staged until Execute, same-ID Commit retransmissions preserve and re-acknowledge the
  ready candidate, and generation-scoped stale membership/external-sender work fails closed. A
  fresh native gate bootstrapped the three pinned libraries and passed 46 tests in 6 suites in both
  debug and release, including output-secrecy probes; the full non-native repository gate also
  emitted `VERIFY-ALL GREEN`. These results advance the local DAVE component boundary but do not
  compose or prove production RTP/Opus send/receive, Apple capture/playback, reconnect/resume, or a
  live DAVE-enabled call, so this goal remains `in_progress`.
- **Phase 4 negotiated-media bootstrap 2026-08-03:** the Voice Gateway now consumes the validated
  Ready SSRC, selected AEAD mode, 32-byte Session Description key, effective DAVE version, and
  Gateway generation into a one-shot session-owned native media plane before returning only
  secret-free readiness booleans to the controller. The Gateway no longer retains the raw Session
  Description; duplicate/stale generations and reset races fail closed, DAVE changes re-attest the
  current epoch, and teardown is ordered media reset → Voice WebSocket → retained UDP. The native
  factory remains `.unavailable` and advertises DAVE 0 because no production packet pump exists.
  Focused Core verification is 67/67 and the fresh pinned native gate passed 52 tests in 7 suites
  in debug and release with output secrecy and `NATIVE_MEDIA_SMOKE_GREEN`. This closes the local
  Phase 4 bootstrap boundary only; protected packet send/receive, capture/playback, reconnect,
  UI, and live evidence remain open, so the goal stays `in_progress`.
- **`/goal continue` 2026-08-04:** dispatched three parallel worktree-isolated slices against the
  open Phase 4 residuals — (1) Phase 5: compose the installed runtime into one deterministic
  protected 20 ms Opus/RTP send proving DAVE protection, RTP header/clock, AEAD counter,
  speaking-before-send ordering, teardown, and no-plaintext-fallback; (2) a scripted local Voice
  Gateway WebSocket test server to replace in-process fake transports in the voice-gate audit gap;
  (3) `/voice` SwiftUI mute/deafen + honest connection-phase visibility, scoped to existing gateway
  presence only (explicitly not PTT/VAD/volume/device work, which needs capture composition that
  doesn't exist yet). All three are in flight; results and ledger updates land per-slice when each
  agent finishes. Reconnect/resume (`VoiceGatewayClient` dead-code wiring) and AVAudioEngine
  capture/playback composition remain unstarted open residuals for the next continue pass. Live
  join/speak/hear/reconnect/leave evidence stays operator-blocked (no `.env`/token/Keychain entry
  in this environment) and was not attempted.
- **All three `/goal continue` slices landed 2026-08-04.** The voice-gate and `/voice` UI slices
  merged clean on the first pass. The Phase 5 agent hit two transient connection failures (an API
  connection drop mid-response, then a stalled resume) with real, sound work already staged in its
  worktree each time; rather than keep re-dispatching a flaky agent, the session reviewed the
  staged diff directly (correct reuse of existing `DiscordVoiceRTPHeader`/`DiscordVoiceRTPCodec`/
  `DiscordVoiceRTPClock`/`NativeDAVESession.protect` — no invented types) and finished verification
  itself. See `tasks/todo.md`'s Phase 5 entry for what closed: the full protected-send path composes
  and is proven by six properties in `sendAudioFrameComposesTheFullSendPath` plus five dedicated
  fail-closed tests, and `DiscordVoiceGatewaySession` now actually sends the previously-modeled
  Speaking opcode. Nothing in production calls `sendAudioFrame` yet (no capture loop), so the native
  factory still honestly reports `.unavailable` and DAVE 0 — this closes the send-path composition
  boundary only. All three slices verified together in one tree: native gate 59/59 (debug+release),
  the four non-desktop targets 472/472, `STATIC_SECURITY_GREEN`, all `EXIT:0`. This goal remains
  `in_progress` — reconnect/resume and AVAudioEngine capture composition (Phase 6) are the next
  slices, and live evidence stays operator-blocked.
- **`/goal continue` 2026-08-20: buffered resume landed (the reconnect/resume residual's
  in-session half).** `DiscordVoiceGatewaySession` gained a bounded transport loop: a resumable
  close on an established session retains credentials/keys/media plane, backs off through an
  injected `VoiceGatewayReconnectBackoff`, reopens the same endpoint, and resumes via op-7/op-9
  with the attempt budget refilled only by a successful Resumed; every other outcome (including
  budget exhaustion and operator disconnect mid-backoff) takes the pre-existing credential-dropping
  teardown. New `.resuming` session phase keeps snapshots honest. Verified: five new multi-attempt
  harness tests, full `AbbeyCoreTests` 312 green, desktop smoke green (see todo bullet for the
  in-log evidence). Explicitly NOT closed: automatic controller-level full-reconnect
  (`DiscordVoiceController.reconnect()` remains production-uninvoked), induced UDP/invalid-session/
  channel-move/shutdown verification, and live-network resume evidence (operator-blocked).
- **`/goal continue` 2026-08-20 ~03:00 (third pass): controller full-reconnect fallback landed** —
  the reconnect/resume residual's second half, in worktree `codex/voice-reconnect-fallback-20260820`
  to stay clear of the three in-flight parallel agents. `awaitTermination()` on the session-client
  seam (default-inert for unaware clients), a generation-scoped post-ready monitor, and a bounded
  auto-rejoin budget (default 2, refilled only by a fresh operator join, exhaustion fails closed
  as `.gatewayUnavailable`). Kick/move policy is structural, not close-code guessing: Discord-
  authoritative removal clears the target and advances the generation through the bridge's leave
  barrier, which inertly retires the monitor. Two real races were caught and fixed during
  verification: an actor-reentrancy stomp of `.failed` by the join tail (monitor now starts
  strictly after the ready transition) and a test-harness sleeper collision (credential-timeout
  race vs. backoff on one injected sleeper). Controller suite 22/22 ×10, AbbeyCoreTests 317
  green. Reconnect/resume is now Current at both layers (in-session buffered resume + controller
  full rejoin); still open in that todo bullet: induced UDP loss/reorder, invalid-session,
  channel-move, process-shutdown verification, and operator-blocked live evidence.
- **`/goal continue` 2026-08-20 ~02:55 (second pass, parallel dispatch):** unbroke the red linux CI
  job first — `web/bun.lock` is lockfileVersion 2 (bun 1.4.0) while CI pinned bun 1.2.19, and the
  "Test dashboard SPA" step ran `bun test` (bun's own runner, no `vi.stubGlobal`/DOM) against vitest
  suites; fixed to bun 1.4.0 + `bun run test`, verified locally (install/lint/build green, vitest
  17/17), pushed to PR #60 (`d7a36e7`). Then dispatched three worktree-isolated agents: (1) Phase 6a
  AVAudioEngine capture composition into the production `sendAudioFrame` path; (2) video-goal
  DAVE-protect/AEAD/RTP send extension to `.video` frames (see that goal); (3) swiftly-snapshot
  server-graph parity (see new goal below). In flight — results and honest boundaries land
  per-slice when each agent returns. Live evidence remains operator-blocked and was not attempted.

## Complete Discord video and Go Live
status: in_progress
- Discord camera video and Go Live screen sharing are separate from the audio completion claim and
  are not shipped. Completion requires Voice Gateway video source/sink signaling, camera and screen
  capture permissions, negotiated video codec and RTP pipelines, DAVE video-frame encryption,
  receive/render paths, SwiftUI controls, congestion and loss recovery, and live DAVE-enabled camera
  plus Go Live validation.
- Video capture is opt-in and visibly indicated. Never persist raw camera, screen, encoded video, or
  DAVE material by default; screen capture must fail closed when macOS permission is absent or the
  operator activates the capture kill switch.
- Completion evidence must cover deterministic source/sink opcode fixtures, codec and RTP golden
  tests, packet loss/reorder/congestion simulations, camera and screen-device interruption, bounded
  CPU/memory/thermal behavior, the full repository gate, and live send/receive evidence for both a
  camera stream and a Go Live screen stream.
- **Audit 2026-08-01 (read-only, against `2a423e1`):** no checklist item is closeable. The one
  real asset is the capture engine — genuine AVFoundation/ScreenCaptureKit `VideoCaptureAdapter`
  with 17 hermetic tests — but it has no preview and no app code path can start it. Video
  signaling, video RTP/codec negotiation, DAVE video callers/tests, and render/start-stop UI are
  absent (inbound video opcode 12 is an explicit error). 9 of the 11 required fault/perf scenarios
  are structurally unreachable until a video transport exists. Written docs and UI copy remain
  claim-honest. Full detail in `tasks/todo.md` → "Video audit snapshot".
- **PR #55 validation 2026-08-03 (against merged `433eb17`):** camera and Go Live cannot be live
  validated from this revision. The app can explicitly request camera/screen permissions, but it
  has no camera or screen start controls, preview, video signaling, negotiated codec/RTP path, or
  DAVE-protected video wire path. Those are engineering blockers, not manual Discord steps. The
  later app-signing repair makes the permission-preflight UI launchable but adds none of those
  missing media paths. The goal remains `in_progress` and no camera/Go Live evidence is claimed.
- **Post-PR #55 integration follow-up 2026-08-03:** bounded Voice Gateway v8 video source/sink
  models now cover stream/SSRC allocation, Opcode 12 announcements and clearing, Opcode 15 sink
  wants, participant audio/video/RTX ownership, and outbound-only wire validation; the focused
  gateway suites pass 44/44. A generation-scoped bounded local capture stream and SwiftUI camera
  preview now clear terminal/stale pixels and stop on view disappearance or the kill switch.
  This is signaling and local-preview proof only: source selection UX, negotiated codec/RTP,
  remote rendering, DAVE video-frame transport, fault/performance coverage, and live camera plus
  Go Live evidence remain open, so this goal remains `in_progress`.
- **`/goal continue` 2026-08-04: deliberately deferred, not stopped.** This pass's audio-side
  Phase 5 slice (see the voice-audio goal above) is actively composing the production call site for
  `NativeDAVESession.protect(...)` and the AEAD/RTP send path in the same files this goal's DAVE
  video-frame and video-RTP items would need to extend (`NativeDAVESession.swift`,
  `DiscordVoiceTransportEncryption.swift`, the RTP header/clock pieces in `DiscordVoiceRTP.swift`).
  Starting DAVE-video or video-RTP work concurrently — even in an isolated worktree — would either
  duplicate Phase 5's composition pattern before it exists or create a merge conflict on those
  shared files once both land. Non-colliding video work (render/UI beyond what's already landed,
  source-selection UX) was not started this pass either, to keep this session's coordination bounded
  to the three in-flight slices. Next continue pass: once Phase 5 lands, extend its
  DAVE-protect/AEAD/RTP call pattern to `.video` frames rather than re-deriving it. Goal remains
  `in_progress`; no new evidence this pass.
- **`/goal continue` 2026-08-20: the deferred slice is now dispatched.** Phase 5 landed on the
  audio side, so a worktree-isolated agent is extending its DAVE-protect/AEAD/RTP call pattern to
  `.video` frames exactly as the 2026-08-04 note prescribed: video SSRC from the landed Opcode
  12/15 source/sink models, 90 kHz RTP clock and marker-bit frame boundaries, announcement-before-
  send, fail-closed on plaintext fallback and stale generations, with a Phase-5-style composition
  proof plus fail-closed tests. Scope is the video send boundary only — no capture wiring, codec
  negotiation completion, rendering, or live claims. In flight; evidence lands when the agent
  returns.

## Cross-platform server-graph toolchain parity (swiftly snapshot)
status: in_progress
- Goal: local development gets a first-class swiftly-managed Swift 6.4/6.5 development-snapshot
  path for the server graph (AbbeyCore/AbbeyServerKit/AbbeyServer/AbbeyCLI under
  `ABBEY_PACKAGE_ROLE=server`), matching CI's `swiftlang/swift:nightly-6.4.x-bookworm` Linux image
  — WITHOUT disturbing the desktop's Xcode toolchain path (`.swift-version` stays `xcode`; SwiftData
  macros break under snapshot toolchains, so the swiftly selection is per-invocation only, never
  the global default).
- Acceptance: a committed `Scripts/check-server-snapshot.sh` that resolves/builds/tests the four CI
  server suites under the snapshot with real per-gate exit codes, AGENTS.md documenting the path,
  and the Xcode desktop build still green.
- **`/goal continue` 2026-08-20: dispatched** as one of three parallel worktree-isolated slices.
  In flight; evidence lands when the agent returns.

## Release and SwiftData hardening
status: done
- Preserve sync persistence and migration compatibility across previously released database and
  cursor representations, with literal upgrade fixtures rather than same-version round trips.
- Keep secrets and user-authored sync content off plaintext non-loopback transport; local HTTP and
  Docker exposure remain explicit loopback-only development paths.
- Treat SwiftData save as the commit boundary for remote memory pushes, success acknowledgments,
  reputation cache/events, and equity generator/events. Failure paths roll back local context and
  do not emit committed-looking side effects.
- Make `Scripts/verify-all.sh` the actual release authority across static/security, dashboard,
  every local Swift test bundle, desktop launch, server HTTP/database smoke, and CLI isolation.
- Focused evidence is green: cursor stores, migration matrix, sync transport, memory commit,
  reputation commit, dashboard, static/security, CLI wrapper under hostile env, and 50/50 direct
  CLI protocol iterations. Final combined `Scripts/verify-all.sh` is green across all local gates;
  server smoke used the documented SQLite-file fallback because Docker/Postgres was unavailable.

## Harden Twitch EventSub retry semantics and webhook ack model
status: done
- **Six original code-review findings (self-echo mislabeled as duplicate, retry-duplicated audit
  rows, missing ack model, fragile claim/release, `BotRuntime+Twitch.swift` extraction) — closed
  and verified.** `TwitchEventSubRoutes.swift` 190 → 168 lines while gaining a function;
  `BotRuntime.swift` 935 → 819 via the extraction.
- **Reopened scope, both items done:**
  - `TwitchEventSubReplayGuard` is now Fluent-backed (`Models/TwitchEventSubDelivery.swift`) —
    durable across restarts, shared across instances. A unique-constraint insert is the atomic
    claim; `release` hard-deletes for re-claimability; fail-closed on DB error.
    **Migration follow-up fixed this session:** `CreateAll` remains the fresh-schema/whole-revert
    owner, while registered `AddTwitchEventSubDeliveries` uses `.ignoreExisting()` to support both
    databases whose logged historical `CreateAll` lacks the table and databases where a newer
    `CreateAll` body already created it. The compatibility migration's revert is a deliberate
    no-op so it cannot delete a table it merely adopted. A deterministic SQLite upgrade matrix
    covers all three populations, repeated prepare, uniqueness, and rollback ownership.
  - `handleTwitchChannelSocial` now publishes `AbbeyEvent.twitchChannelSocial` and credits
    `guildId=twitch` reputation via the existing `FluentSocialBrain.recordInteraction` (EMA
    targets: follow 0.65, cheer 0.80, subscribe 0.90; anonymous cheers skip reputation) — all
    strictly gated on `.inserted`, verified idempotent on retry by mutation testing.
- **Doc-honesty fixes applied:** AGENTS.md (lines ~65, ~190) and CLAUDE.md (Twitch bullet) updated
  — they said "typed-ack + log only" and "in-memory" replay guard; both were false against the
  shipped code.
- **Cross-session conflict audit: none found.** A dedicated read-only investigation confirmed the
  replay-guard table and the ingest-key dedupe are a deliberate two-layer design (fast path +
  durable backstop), not competing implementations — single linear git history for every file
  touched, no duplicate migrations, no conflict markers. One coverage gap noted (no test exercises
  both dedupe layers together) — not a defect, worth a follow-up test.
- **Live Helix/EventSub handshake: still not achievable in this environment** — needs a public
  HTTPS callback this box doesn't have. Don't mark this done off a green local test.
- **Strict code-quality pass on the replay-guard/reputation/route code (2026-08-01 ~02:00):**
  one moderate finding — the EventSub route closure was doing three jobs inline (auth verify,
  replay-guard claim, dispatch+release) across ~108 lines, this diff's own doing. Extracted
  `verifySignature(req:messageId:rawBody:)`, mirroring the existing `apply()` extraction one level
  up. Pure move, no logic change. Verified: 130 tests green, exit 0
  (`AbbeyServerAuthTests` 21 + `AbbeyServerKitTests` 109), all six route-behavior tests confirmed
  individually. Everything else reviewed (`TwitchEventSubReplayGuard.swift`,
  `BotRuntime+Twitch.swift`, `EventBus.swift`, `SyncPageDrain.swift`, `SyncEndpointIdentity.swift`)
  came back clean — no structural regressions, no bespoke helpers duplicating canonical ones.
- **Regression found and fixed after the above was already marked verified (2026-08-01 02:20):**
  a later concurrent edit to `AddTwitchEventSubDeliveries.swift` dropped `.ignoreExisting()` from
  the `.create()` chain while leaving the doc comment describing the old (correct) behavior — code
  and comment had drifted apart. Confirmed as a live, reproducible boot-breaking bug, not a stale
  build artifact: `swift test --filter TwitchEventSubMigrationUpgradeTests` failed 3 of 4 cases
  with `table "twitch_eventsub_deliveries" already exists`, and `Scripts/run-server-smoke.sh`
  failed the same way against a fresh sqlite file (`CreateAll` creates the table, then the forward
  migration's plain `.create()` collided with it). Restored `.ignoreExisting()`; re-ran both —
  all 4 migration-upgrade tests pass and `run-server-smoke.sh` completes with `SERVER SMOKE GREEN`,
  `EXIT:0`, including live `/api/ingest`, list-API, and tombstone assertions.
  **Lesson for next reader:** a green report from one point in this session does not stay green —
  this file was edited again afterward by another concurrent agent in this same shared tree. The
  gate belongs to the code on disk right now, not to whichever run was quoted most recently.
- **Historical transient full-gate failure, now resolved.** A run at
  02:00 hit `error: cannot find 'SyncTransportPolicy' in scope` in
  `Sources/AbbeyCore/AppConfig+Validation.swift` during the release build step; that file and its
  call site belong to unrelated concurrent work (new `Sources/AbbeyCore/Sync/SyncTransportPolicy.swift`,
  still untracked) and the same file compiles cleanly moments later once that other session's edit
  lands — a timing race across two files being written by different sessions, not a regression in
  anything this goal touched. Also worth recording precisely because it was easy to miss: the
  background command that ran this used `cmd > log; echo "EXIT:$?" >> log` — the reported
  background-task "exit code 0" reflects the trailing `echo`, always 0, **not** `verify-all.sh`'s
  real result (which was 1). The real result only lives in the log's own `EXIT:` line. Use `&&` or
  check the in-log `EXIT:` marker, never the wrapper task's reported exit code. A later combined
  `Scripts/verify-all.sh` run completed green and is the current release authority.
- **Historical migration-scoped gate, superseded by the later combined green gate:** isolated
  `swift build --target AbbeyServerKit` exit 0;
  `TwitchEventSubMigrationUpgradeTests` 4/4 green; `Scripts/run-server-smoke.sh` green end-to-end
  including the migration boot path and live `/api/ingest` + list-API + tombstone assertions;
  `swift test --filter 'AbbeyCoreTests|AbbeyCLITests|AbbeyServerKitTests|AbbeyServerTests'` — 255
  tests green, exit 0 (21 + 117 + 87 + 30 across the four non-desktop targets). Desktop
  (`AbbeyBotAppTests`) not re-run this pass — it uses SwiftData, not Fluent, so it cannot exercise
  a Fluent migration change; it was green in the last full `verify-all.sh` baseline before this
  regression existed and nothing in this fix touches desktop code.
- **Not pushed.** Current work is isolated on `codex/massive-improve-cleanup` for review.

## Retire the legacy sync-cursor policy layer
status: done
- **All three findings from the code-quality review applied and verified.**
  - **#1** Deleted the dead `IncrementalSyncCursor.next(...pages:)` overload and `Page` struct
    (zero production callers), deleted the 5 legacy-only tests, ported the two genuine edge cases
    (server-clock-ahead, missing-boundary-on-full-page) onto the compound overload's coverage —
    fixing a real coverage inversion where the tested code path wasn't the one that ran.
  - **#2** Collapsed `SyncPullCursorSet` from six optional fields + a six-case switch subscript to
    a single `private var values: [SyncPullEntity: SyncPullCursor]`. Public API (labeled init,
    `legacyTimestamp` init, subscript, `earliestChangedAt`) remains unchanged. The refactor initially
    changed synthesized `Codable` storage; custom dynamic-key coding now preserves released flat v2
    JSON and accepts the transient nested dictionary representation. Literal fixtures are green in
    core, desktop `UserDefaults`, and CLI file-store tests.
  - **#3** Added a doc comment on the short-page tie-breaker loss, corrected for the
    `serverHighWatermark` mechanism the other session added concurrently (the original "client
    clock" justification was stale — the upper bound is now usually a server-issued timestamp).
- Verified via a dedicated build/test agent: server-role build exit 0, desktop build exit 0,
  241 + 36 = 277 tests green, no fixes needed beyond what was applied.

## Align CLAUDE.md with what the build actually requires
status: done
- Added the five test targets and which three Linux CI runs, the `ABBEY_PACKAGE_ROLE=server`
  requirement, the `?since=` truncation gap (since closed by the compound-cursor work above), and
  a warning against piping build output through `tail` (masks the exit code).

## Apply strict code-quality findings from PR #53's merged diff
status: done
- Both findings applied (2026-08-01). **#1** `SyncTransportPolicy.makeRequest(baseURL:path:method:queryItems:bearerToken:)`
  is now the single request-building boundary in AbbeyCore (validate → strip slash → join
  path/query → attach Bearer; nil/empty token omits the header); `ServerSyncClient.makeRequest`
  and `AbbeyServerClient.makeRequest` both delegate, keeping only their own error mapping. Three
  new AbbeyCore tests cover join/token attach, nil-vs-empty token omission, and
  rejected-transport throw. **#2** The dead `transientValuesKey` decode branch is deleted from
  `SyncPullCursorSet.init(from:)`; all three fixture tests that asserted the dev-only format
  decoded (core, desktop store, CLI file store — the third surfaced by the full-bundle run after
  the first grep missed it) were repurposed to assert the safe degradation: empty set → full
  bootstrap pull, never a bogus cursor and never misread as a legacy epoch.
- Verified in a tree carrying concurrent in-flight voice work: server-role
  `AbbeyServerTests` 21 + `AbbeyCoreTests` 234 + `AbbeyCLITests` 30 green in one run, then
  `AbbeyServerKitTests` 117 green after the third-fixture fix (in-log `EXIT:0`, not the wrapper
  code); desktop `SyncCursorStoreTests` + `AbbeyServerClientTransportTests` 17 green with the
  full desktop build (including the in-flight voice/media targets) completing. Committed on
  `cursor/complete-discord-voice` (`1e5b6e6`/`2a423e1`) and landing through PR #55 — the original
  intent to land on a separate scoped branch was overtaken when a concurrent session swept the
  working tree into its own commit; recorded here so the ledger matches the branch's real contents
  (corrected 2026-08-01 after PR #55 code review flagged the stale claim).
- A strict code-quality review of `aa1fb60...b585947` (the diff that merged as PR #53, ~1500 lines
  / 41 files) surfaced two confirmed structural findings, not yet applied:
  1. **Duplicated transport-request builder.** `ServerSyncClient.makeRequest`
     (`Sources/AbbeyServerKit/Sync/ServerSyncClient.swift`) and `AbbeyServerClient.makeRequest`
     (`Sources/AbbeyBotApp/AbbeyServerClient.swift`) are near-identical: validate `baseURL` via
     `SyncTransportPolicy`, strip trailing slash, join path+query, attach Bearer token. The PR
     added `SyncTransportPolicy` in AbbeyCore as the one shared transport-security boundary but
     stopped one call site short of eliminating the duplication risk it exists to prevent.
     Remedy: hoist the shared request-building logic into AbbeyCore (e.g. on
     `SyncTransportPolicy`), parameterized by base URL/method/query/token, and have both clients
     call it.
  2. **Dead compat branch in `SyncPullCursorSet.init(from:)`**
     (`Sources/AbbeyCore/Sync/SyncPullCursor.swift`). Decodes a `"values"`-keyed nested-dictionary
     format that only a short-lived development build inside this same session ever wrote —
     never released. The sole call site (`SyncCursorStore.pullCursors`) already wraps the decode
     in `try?` and degrades to a fresh cursor on any failure, so the branch guards a scenario that
     already self-heals. Remedy: delete the `transientValuesKey` branch and its comment; keep only
     the flat per-entity-key decode loop matching the real released v2 format.
- Both are low-risk, mechanical fixes. Not yet executed — awaiting confirmation this capture
  reflects actual intent (args arrived as a verbatim paste of the review's own summary message).

## Branch state — reconciled onto a review branch
- This working tree was, over roughly 90 minutes, edited concurrently by this session, two
  subagents this session dispatched, and at least one other AI coding tool (evidenced by
  `cursor/*` and `codex/*` local branch names). The other tool independently merged the feature
  branch into local `main` and made further commits directly on `main`, bypassing this repo's own
  documented PR-only workflow for `main`. The user was informed and explicitly chose to **keep**
  that local merge rather than unwind it.
- `origin/main` moved independently during the earlier work. The retained local commit and dirty
  changes were moved to `codex/massive-improve-cleanup` and rebased on current `origin/main`.
- Local `main` was safely realigned to `origin/main`; no force-push occurred. Continue through the
  feature branch and PR workflow, never by committing or pushing this work directly to `main`.
