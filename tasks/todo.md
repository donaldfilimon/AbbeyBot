# Todo

Granular steps under `tasks/goals.md`. Coarse intentions live there, not here.

## Apply strict code-quality findings from PR #53's merged diff — done

- [x] Dedupe `ServerSyncClient.makeRequest` / `AbbeyServerClient.makeRequest` behind a shared
      AbbeyCore helper — added `SyncTransportPolicy.makeRequest(baseURL:path:method:queryItems:bearerToken:)`
      (validate→strip-slash→join-path/query→attach-Bearer-token, empty/nil token omits the
      header); both clients now delegate and keep only their own error mapping
      (`ClientError.invalidURL` / `SyncClientError.notConfigured`+`invalidURL`). Three new
      AbbeyCore tests cover join/token-attach, nil-vs-empty token omission, and
      rejected-transport throw-before-request.
- [x] Delete the `transientValuesKey` decode branch in `SyncPullCursorSet.init(from:)` — dead
      compat for a dev-only format removed along with its doc-comment claims. The two fixture
      tests that asserted the transient format decoded were repurposed to assert the safe
      degradation instead: the payload now decodes to an empty set (core) and the desktop store
      degrades to a full bootstrap pull, never a bogus cursor.
- [x] Third fixture caught by the full-bundle run: `transientDictionaryFixtureSurvivesCLICursorStoreUpgrade`
      in `Tests/AbbeyServerKitTests/ServerSyncApplyTests.swift` (missed by the initial grep) —
      repurposed like the other two to assert the CLI file store degrades to a full bootstrap
      pull and does not misread the payload as a legacy epoch.
- [x] Verified (this tree, concurrent voice work in flight): targeted server-role suites 20 green;
      desktop `SyncCursorStoreTests|AbbeyServerClientTransportTests` 17 green (full desktop build
      completed including in-flight voice/media targets); full non-desktop bundles green —
      `AbbeyServerTests` 21 + `AbbeyCoreTests` 234 + `AbbeyCLITests` 30, then
      `AbbeyServerKitTests` 117 after the third-fixture fix (in-log `EXIT:0`).

## Discord application + real voice audio — in progress

- [ ] Harden the DiscordBM main-gateway lifecycle: READY remains the connected authority, explicit
      disconnect closes the pinned manager, failures become observable, and voice presence is not
      reported as joined before Discord confirms the bot's own `VOICE_STATE_UPDATE`.
- [x] Pair the unordered self `VOICE_STATE_UPDATE` and `VOICE_SERVER_UPDATE` events in a
      generation-scoped handshake accumulator; cover both event orders, wrong guild/user/channel,
      nil endpoint, stale partials, cancellation, timeout, and single-emission behavior.
      *(Audited 2026-08-01: `VoiceGatewayHandshake.swift` + `VoiceGatewayHandshakeTests` cover
      every listed sub-requirement; green in the 234-test AbbeyCoreTests run. Bridge-side
      consumption of the accumulator remains untested — tracked under item 1.)*
- [x] Implement the separate Discord Voice Gateway v8 state machine: endpoint normalization,
      Identify, Hello, heartbeat/ACK with `seq_ack`, Ready, Session Description, Speaking, binary
      payload decoding, close-code policy, and bounded parsing.
      *(Audited 2026-08-01: `VoiceGatewayV8StateMachine/Models` + three suites incl. seq wrap,
      ACK mismatch, resume poisoning, close-code policy. Caveat: `speaking(flags:)` is modeled
      and tested but not yet sent by the production session — media pipeline item still open.)*
- [x] Implement UDP/IP discovery and protocol selection, including exact discovery packet fixtures,
      NAT-visible address/port handling, datagram receive, and a real local UDP echo test.
      *(Audited 2026-08-01: exact 74-byte fixtures, one retained socket preserving the NAT
      mapping, Select Protocol actually sent, and real `DatagramBootstrap` loopback tests on
      `127.0.0.1:0` across three suites.)*
- [x] Implement transport encryption with required `aead_xchacha20_poly1305_rtpsize` support and
      advertised AES-256-GCM preference; prove nonce uniqueness, authentication failure, tamper,
      replay, counter-wrap, and known-answer behavior.
      *(Audited 2026-08-01: both RTPSIZE modes, AES-preferred negotiation, nonce reserved before
      suspension, per-SSRC replay bitmap, counter exhaustion → nil. Caveats: RFC known-answer
      vectors live in `NativeAEADTests` which only builds under `ABBEY_NATIVE_MEDIA=1` (CI never
      sets it), and `DiscordVoiceTransportEncryption` is not yet constructed by production code —
      composition tracked under the RTP-pipeline and voice-gate items.)*
- [ ] Integrate a pinned, reproducible build of Discord's official `libdave` C API and implement the
      DAVE/MLS voice opcodes, protocol transitions, roster/key-ratchet management, and Opus-frame
      encryption/decryption. Do not advertise a nonzero DAVE version until this path is real.
- [ ] Add portable libopus bindings and the RTP media pipeline: 48 kHz stereo, 20 ms frames,
      sequence/timestamp/SSRC wrap, speaking-before-send, five silence frames, receive parsing,
      SSRC/user mapping, jitter/reorder buffering, packet-loss concealment, decode, mix, and loopback
      golden tests.
- [ ] Add Apple capture/playback with `AVAudioEngine`: microphone permission, device selection,
      format conversion, mute/deafen, push-to-talk/VAD, output volume, speaker levels, interruption
      handling, and input/output device removal recovery. Keep server audio behind injected source
      and sink protocols rather than assuming physical devices.
- [ ] Add Voice Gateway buffered resume and full reconnect fallback, re-establish UDP/media state
      safely, stop audio on explicit leave, and verify induced WebSocket loss, UDP loss/reorder,
      invalid session, channel move, and process shutdown.
- [ ] Expand `/voice` and the Discord SwiftUI surface with honest connection phases, guild/channel
      selection, join/leave/status, mute/deafen, PTT/VAD, device/volume controls, speaking meters,
      reconnect/error visibility, stage-channel state, permission preflight, privacy policy, and an
      immediate capture kill switch.
- [ ] Add the voice gate: protocol/unit fixtures, scripted local Voice WebSocket, real UDP loopback,
      codec/crypto/DAVE tests, audio-device tests, and fault injection; then run the full repository
      gate. Do not mark live capability complete from local tests alone.
- [ ] Rotate the previously exposed Discord bot token, authorize an isolated test guild/channel,
      and capture live current-protocol evidence for join, DAVE negotiation, speak, hear, network
      reconnect/resume, channel move, and leave without logging credentials or raw audio.

### PR #55 smallest credible live-validation attempt (2026-08-03)

- [x] Fast-forwarded the clean local `main` to GitHub's merged PR #55 commit `433eb17` and
      re-established the proof boundary from the current source rather than the pre-merge audit.
- [x] Host/toolchain preflight: macOS 27.0 (26A5388g), Apple Swift 6.4 via Xcode's default
      toolchain. `Scripts/run-native-media-smoke.sh` exited 0 after a fresh isolated bootstrap of
      libdave 1.1.1, Opus 1.6.1, and libsodium 1.0.22; 37 tests in 6 suites passed in debug and
      release, the debug/release output-secrecy probes passed, and `STATIC_SECURITY_GREEN` /
      `NATIVE_MEDIA_SMOKE_GREEN` were emitted.
- [x] The gate began from a clean `433eb17` checkout. Three concurrent uncommitted native
      source/test edits appeared afterward; they remain outside this validation slice and are not
      staged. Treat the green above as the exact observed run, not as proof of those later edits.
- [x] Packaged a separate app from an isolated `origin/main` worktree at `655ef0f`. The first
      bundle passed `codesign --verify --deep --strict` but exited before app startup: dyld rejected
      ad-hoc `libdave.dylib` under Hardened Runtime because ad-hoc code has no matching Team ID.
      Fixed the packaging script so `com.apple.security.cs.disable-library-validation` is added
      only for ad-hoc builds that actually embed native code; named identities keep validation.
      The rebuilt app passed deep strict signature verification, retained microphone and camera
      entitlements, linked `@rpath/libdave.dylib`, and remained alive through the 16-second launch
      probe. Executable SHA-256:
      `90aad977c361b594363f4a81a004a31165e33803a9700dfa43752ef76fb595f4`.
- [x] Verified the opposite packaging branch from a completed non-native debug build: the ad-hoc
      bundle did **not** contain `com.apple.security.cs.disable-library-validation`, passed signing,
      and completed the media-disabled launch probe. The exception is therefore scoped to an
      ad-hoc bundle that actually embeds native code.
- [x] The original additional `Scripts/run-smoke.sh` attempt was **not green**: isolated debug and
      release builds completed, then `swift test` emitted passing tests but never terminated its
      `AbbeyBotAppTests` helper. The integration follow-up traced the hang to a test-owned suspended
      join continuation: the test awaited disconnect before releasing the request lease that
      teardown intentionally awaits. The test now proves generation preemption first, releases the
      fake request, and then awaits teardown. `MediaSessionModelTests` passes 18/18 in isolation,
      and a fresh final `Scripts/verify-all.sh` completed through all five desktop stages plus web,
      server, and CLI with `VERIFY-ALL GREEN`. This closes the local gate regression only; it is not
      live Discord evidence.
- [x] `Scripts/check-static-security.sh` emitted `STATIC_SECURITY_GREEN`; `bash -n` and
      `git diff --check` passed. HawkScan was not run because neither its runtime/tool nor
      `HAWK_API_KEY` is available in this environment; `shellcheck` is also unavailable.
- [ ] **Live signaling/UDP probe not run.** Preflight found no `.env` / `.env.local`, no
      `DISCORD_BOT_TOKEN` or `DISCORD_DEV_GUILD_ID` in the process or launch environment, and no
      item in Keychain service `com.donaldfilimon.AbbeyBot`. Do not infer a failed Discord path:
      authentication inputs were absent, so no Discord connection was attempted. The verified
      app artifact remains available for the operator to reopen at
      `/var/folders/42/07tmt0n56jq4261xb9gz5jwm0000gn/T/AbbeyBot.PR55.fix.build/AbbeyBot.app`;
      this is an ephemeral local artifact and its successful launch is not a connection.
- [ ] **Manual operator slice, once a rotated token and isolated guild/channel are ready:** open
      the packaged AbbeyBot app; enter the token (Keychain-backed), dev guild ID, and voice channel
      ID; connect; optionally request microphone/camera/screen permissions one at a time; click
      **Probe transport**; confirm the bot briefly appears in the intended voice channel; and
      capture the app's redacted signaling/transport labels plus Discord's observed join/leave.
      Expected honest result from the PR #55 product path: main-gateway credentials, Voice Gateway
      v8, UDP discovery, transport selection, then automatic leave with DAVE/media unavailable.
      No audio, camera, screen, credential, or raw-media recording belongs in the evidence.
- [ ] **Not manual-actionable on this revision:** DAVE audio negotiation/media send and receive,
      audible speak/hear, mute/deafen, reconnect/resume, and channel move remain blocked by the
      production media composition and UI gaps listed above. A successful transport probe must not
      be upgraded into a DAVE-audio claim.

### Post-PR #55 native DAVE integration slice (2026-08-03)

- [x] Hardened the active-session and replacement-session DAVE state machines around
      Proposals → Commit → Execute: Commit ratchets and roster state remain staged until Execute,
      Welcome cannot activate an active Commit candidate, stale membership work fails closed, and
      same-context External Sender recovery remains generation-scoped.
- [x] Made same-ID Commit retransmission idempotent after Transition Ready. A duplicate re-emits
      Ready without re-entering libdave or clearing the staged roster; active and replacement
      tests prove `processCommit` runs once and Execute activates exactly once.
- [x] Fresh isolated `Scripts/run-native-media-smoke.sh` bootstrapped pinned libdave 1.1.1,
      Opus 1.6.1, and libsodium 1.0.22; debug and release each passed 46 tests in 6 suites,
      runtime-output secrecy passed in both configurations, static security passed, and
      `NATIVE_MEDIA_SMOKE_GREEN` was emitted.
- [ ] This does **not** close the DAVE/audio checklist item: production RTP/Opus send/receive,
      capture/playback composition, reconnect/resume, and a live DAVE-enabled call remain open.

### Voice audit snapshot (2026-08-01, read-only, two parallel agents)

Open items above, graded against the committed tree at `2a423e1`:
- **Item 1 (gateway lifecycle) PARTIAL** — implementation hardened (generation-scoped READY
  authority, presence only from confirmed self `VOICE_STATE_UPDATE`, real `disconnect()`), but
  `DiscordBridge.handleVoiceStateUpdate`/`handleVoiceServerUpdate` have zero bridge-level tests.
- **libdave/DAVE PARTIAL** — pinned libdave 1.1.1 binding (`NativeDAVESession`) is real MLS, never
  enables passthrough, and nothing advertises nonzero DAVE (honest default 0). Missing piece is the
  control-handler bridge: production factory passes `.portableUnavailable`. A concurrent session
  has the bridge (`NativeDAVEControlAdapter`) in flight, untracked at audit time — once it lands,
  re-audit the "do not advertise nonzero until real" constraint.
- **Opus/RTP PARTIAL** — real libopus binding + RTP header/clock/replay pieces exist, but no
  jitter/reorder buffer, no PLC integration, no mixing, no silence frames, no loopback golden test,
  and nothing composes the parts: `nextAudioFrame()`/`sendProtectedPacket`/transport encryption are
  never called from production sources.
- **AVAudioEngine PARTIAL** — real engine adapter, permissions, device catalog, 20 ms framing,
  mute/deafen, interruption events, hermetic tests; missing PTT/VAD, output volume, speaker levels;
  device removal is stop-without-restart. macOS media tests never run in CI (no macOS job).
- **Reconnect/resume PARTIAL** — `VoiceGatewayClient` implements resume/backoff/close-code
  dispositioning with 14 tests but is dead code: the production factory builds
  `DiscordVoiceGatewaySession`, which has no reconnect; "buffered" resume exists nowhere.
- **`/voice` + UI PARTIAL** — honest presence-only copy, kill switch, device pickers, disclaimed
  meters; missing mute/deafen/PTT/VAD/volume controls and stage state.
- **Voice gate PARTIAL** — real UDP loopback yes; scripted local Voice WebSocket server no (all
  gateway tests use in-process fake transports); `ABBEY_NATIVE_MEDIA=1` suites are outside CI.
- **Item 12 (live evidence) MISSING** — no rotation record, no live-run artifact; blocked on a
  real guild + operator, not on code in this environment.

## Discord video + Go Live — in progress

- [ ] Implement Voice Gateway video source/sink and stream signaling, including SSRC allocation,
      source announcements, sink wants, stream lifecycle, participant mapping, resume, and bounded
      JSON/binary opcode fixtures. Keep this independently incomplete from voice audio.
- [ ] Add opt-in Apple camera and screen-capture sources with camera, microphone, and Screen & System
      Audio Recording permission handling; expose visible capture state, source selection, preview,
      window/display selection, and an immediate capture kill switch.
- [ ] Add negotiated video codec and RTP send/receive pipelines with pacing, timestamps, keyframes,
      frame dependency handling, retransmission/feedback, receive reassembly, and decoder recovery.
      Do not claim a specific codec until the implemented Discord negotiation selects it live.
- [ ] Extend the pinned libdave bridge for DAVE video-frame encryption/decryption, protocol and epoch
      transitions, per-sender ratchets, roster changes, authentication failure, and tamper/replay
      tests without persisting video keys or captured frames.
- [ ] Add render and SwiftUI controls for camera preview, remote participant tiles, Go Live preview,
      source/status indicators, start/stop, quality limits, and operator-visible permission,
      negotiation, congestion, decode, and reconnect failures.
- [ ] Test packet loss, reorder, jitter, bandwidth collapse/recovery, keyframe loss, source/device
      removal, screen lock, suspend/resume, long-session memory growth, CPU/thermal pressure, and
      audio/video synchronization using deterministic local transports and fixture media.
- [ ] Run the full repository gate, then capture live current-protocol evidence for DAVE-protected
      camera send/receive and Go Live screen send/receive, reconnect/resume, source switching, and
      clean stop in an isolated guild using a rotated token. Local fixtures alone cannot close this
      item.

### PR #55 camera / Go Live validation result (2026-08-03)

- [ ] **No live camera or Go Live run is possible from merged `433eb17`.** The permission buttons
      are real preflight only: the app has no camera/screen start action or preview, and the product
      has no video source/sink signaling, negotiated codec/RTP pipeline, render path, or connected
      DAVE video-frame path. The later signing fix proves the entitlement-bearing app can launch;
      it does not make either permission preflight into a camera or Go Live wire path. Do not ask
      the operator to click around Discord as a substitute for these missing product paths. After
      those engineering items land, the remaining manual slice is to select camera and screen
      sources in the isolated guild and independently verify remote receive, reconnect/resume,
      source switching, and clean stop for each track.

### Post-PR #55 video signaling and local-preview slice (2026-08-03)

- [x] Added bounded Voice Gateway v8 video signaling models and fixtures for Ready stream
      allocation, Opcode 12 source announcements/clearing, Opcode 15 Media Sink Wants, and
      participant audio/video/RTX ownership. Outbound Opcode 12 validation rejects server-owned
      `user_id`, missing or mismatched active RTX, and ambiguous clearing shapes while preserving
      Discord's more flexible inbound event decoding. The integrated VoiceGatewayV8 suites pass
      44/44.
- [x] Added a generation-scoped, bounded local capture event stream and SwiftUI camera preview.
      Terminal states and view disappearance stop capture and clear pixels; delayed frames from an
      older generation cannot reappear after restart; the immediate kill switch remains available.
- [ ] This is a bounded Phase 11/12 slice, not shipped camera or Go Live. Automatic first-source
      capture is not full camera/display/window selection, and there is still no negotiated video
      codec/RTP send/receive, remote rendering, DAVE video-frame wire path, congestion recovery, or
      live camera/screen evidence.

### Video audit snapshot (2026-08-01, read-only)

Nothing checkable; graded against `2a423e1`:
- **Signaling MISSING** — no video opcodes exist; inbound opcode 12 is an explicit
  `unsupportedOpcode` error; no video SSRC allocation, no source announce/sink wants.
- **Capture PARTIAL (the real work so far)** — `VideoCaptureAdapter` is genuine
  AVFoundation/ScreenCaptureKit with permission gating, source enumeration/selection, screen-lock
  kill, bounded queues, and 17 hermetic tests. But there is no preview surface, and nothing in the
  app can call `startCapture()` — `MediaSessionPlatform` exposes only `stopAllCapture()`.
- **Video RTP/codec MISSING** — `DiscordVoiceRTPMediaKind.video` is a label only; no pacer,
  keyframes, RTX/feedback, reassembly, or negotiation fields on Select Protocol.
- **DAVE video PARTIAL** — `NativeDAVESession` accepts `.video` + five codecs but has zero video
  callers and zero video tests; only audio protect/unprotect is exercised.
- **Render/UI MISSING** — read-only "Camera capture: Stopped" labels; no preview, tiles, or
  start/stop controls; `daveLabel`/`captureLabel` hardcoded to unavailable copy.
- **Fault/perf tests** — 2 of 11 scenarios exist (screen lock, device removal); the other 9 are
  structurally unreachable until a video transport exists.
- Claim-honesty: video-shaped vocabulary (`videoQueue`, `.video` media kinds, capture status UI)
  greps like a video feature but has no wire path; written docs (`discord-voice-architecture.md`,
  UI disclaimers) remain honest.

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
