# Goals

## Full Swift product integration and release
status: in_progress
- Current evidence: [2026-09-16 integration ledger](../docs/verification/product-integration-2026-09-16.md);
  the [2026-09-08 ledger](../docs/verification/product-integration-2026-09-08.md) is history.
- Canonical `main`, `origin/main`, and remote `main` were observed equal at
  `a9b6c1712178b664d217eab03b55e0c2475f66d3`; ordinary and native release gates
  and hosted CI/release workflows passed on that exact SHA. Production rollout
  remains blocked on Hostinger SSH access, domain registration/delegation,
  private registry access and privately configured provider/backup credentials.
- Live service acceptance and participant-consented audio/video qualification
  remain separate requirements; video promotion also needs the observed codec's
  typed negotiation and final production composition.
- Re-certified 2026-09-16 13:3x EDT at `2143a64` (seven PRs past `a9b6c17`): all five local
  gates green with exit codes read from their logs (`verify-all` 520 desktop tests / 49 suites;
  native 102 / 9 in debug and release; deployment control flow 30; server snapshot Core 520,
  Quasar 84, CLI 30, ServerKit 122, Server 34; Linux musl cross-compile plus glibc lint).
  Hosted CI and release have not run since 09-08: every push shows a `startup_failure` with
  zero jobs, which is the account billing lock, so no image exists for this candidate. SSH is
  still denied, `xfoss.dev` is unregistered, and the CLI token lacks `read:packages`; each was
  re-measured, not assumed. `check-server-linux.sh` gained bundle-plus-`--triple` SDK selection
  because two installed static-Linux SDKs made the old triple query ambiguous. Status stays
  `in_progress`: every remaining row is an operator action or live evidence.

## Complete Discord application and real Discord Voice audio
status: blocked
blocked-on: a rotated Swift Discord application token, an authorized DAVE-enabled
test guild and participant consent for live qualification. Final video negotiation
and composition additionally depend on the observed codec; local tests do not
remove that implementation or acceptance requirement.
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
  factory still honestly reports `.unavailable` and DAVE 0 **[SUPERSEDED 2026-08-20 — see the
  Phase 6a entry below: `sendAudioFrame` now has a production caller via
  `MediaSessionModel` → factory → `DiscordVoiceCaptureLoop`. Left in place as the historical
  record, annotated so nobody stops reading here.]** — this closes the send-path composition
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
  as `.gatewayUnavailable`). Kick/move policy: before any rejoin the fallback consults the pair
  bridge's main-gateway presence evidence (`voicePresenceHeld()`, wired to
  `DiscordBridge.voicePresenceState().confirmedInChannel`); a Discord-authoritative removal reads
  as presence lost and fails closed instead of rejoining. (Review corrected an earlier claim that
  the bridge clears the controller's target on removal — no such wiring exists; the presence gate
  is the real mechanism.) Two real races were caught and fixed during
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

- **`/goal continue` 2026-08-20 ~06:20 (third pass, integration + review).** Landed on the branch:
  (a) all five automated-review findings on PR #60, each with a regression test that fails on the
  previous behavior — the Speaking gate no longer latches before its callback succeeds (a failed
  or still-suspended signal can no longer let a frame reach the UDP transport), `reset()` now
  cancels and awaits suspended datagram sends, a missed heartbeat ACK no longer resets the media
  plane it is about to resume onto, a confirmed server-side channel move retargets later mute
  updates, and the desktop mute/deafen toggles compose through one pending pair instead of undoing
  each other; (b) the red linux CI job's real cause — `URLSession` is unavailable in Foundation on
  Linux, so `RemoteOpenAICompatibleProvider` failed to build; it now carries the
  `canImport(FoundationNetworking)` guard the rest of the repo already used (every server-graph
  file referencing URLSession/URLRequest/HTTPURLResponse was audited; this was the only gap).
  Verified locally: AbbeyCoreTests 314/314, AbbeyBotAppTests 70/70, native gate
  NATIVE_MEDIA_SMOKE_GREEN + STATIC_SECURITY_GREEN in debug and release, all EXIT:0.
  (c) **Phase 6a capture composition landed** — with a correction to this entry's first draft. Its
  agent was killed by a session limit before it could run any gate, so the work was first preserved
  as an explicitly unverified commit; on review it turned out to be complete and correct, not
  half-written (it built clean and its own suite passed on first run — the agent died before
  *reporting*, not before *working*). Reviewed by hand, then integrated: `DiscordVoiceCaptureLoop`
  (revision-guarded, fail-closed on malformed framing / send failure / unexpected stream end,
  ordered teardown that drains the pump before the media plane may reset, redacted diagnostics,
  no key material), `MicrophoneCaptureSource`, controller mute-gating, and the native factory
  binding the loop to the session's own media plane.
  **This closes the composition boundary: `sendAudioFrame` now has a production caller** — capture
  → 20 ms PCM → Opus → DAVE protect → RTP → AEAD → UDP composes end to end in the shipped path,
  where before this pass nothing called it. **What that does NOT mean:** it has never been
  exercised against Discord. `mediaAdapterAvailability` stays `.unavailable` and the advertised
  DAVE version stays 0, deliberately — receive/playback do not exist, and composition is not
  evidence of interoperability. Live join/speak/hear/reconnect/leave evidence remains
  operator-blocked (no token/guild in this environment) and was not attempted.
  Full integrated verification: AbbeyCoreTests 327/327, AbbeyBotAppTests 74/74, native gate 75
  tests in 8 suites in debug AND release, STATIC_SECURITY_GREEN, NATIVE_MEDIA_SMOKE_GREEN, all
  EXIT:0.

- **`/goal complete all / cleanup all` 2026-08-20 ~07:1x.** Found that **PR #60 was merged at
  13:05 UTC while work was still landing on its branch**, stranding ten commits behind a closed
  PR; reunited the histories and opened **PR #64** for them. Swept the repository for orphaned
  work at the same time and found two agent branches nobody had merged, both worth keeping:
  hermetic UDP loss/reorder/corruption fault injection (directly one of this goal's required
  evidence items) and deterministic Twitch loopback connection-state tests. Both are now
  integrated — AbbeyCoreTests 333/333 (from 327), AbbeyBotAppTests 74/74, build exit 0.
  Cleanup: 8 worktrees removed (3 were stale pointers into the deleted `~/Desktop/AbbeyBot`) and
  8 fully-merged branches deleted. Deliberately left alone: the `voice-reconnect-fallback`
  worktree and branch, which carry another session's in-flight work (a live-disconnect
  termination-signal fix and a cursor-mirror doc sync) that is **not** in PR #64 and still needs
  its owner — note it independently landed the same `import Observation` fix, so it will conflict
  trivially on that file.

- **Landed on `main` 2026-08-20 as `198e0a1`.** Everything from this session's branch plus the
  sibling reconnect-fallback branch is now in `main`, verified together on the merge commit:
  AbbeyCoreTests 340/340, AbbeyBotAppTests 74/74, AbbeyServerKitTests 117/117, native media gate
  75 tests in 8 suites in debug AND release, `STATIC_SECURITY_GREEN`, `NATIVE_MEDIA_SMOKE_GREEN`,
  all EXIT:0. Merging the two reconnect halves surfaced one real defect that neither branch hit
  alone: the capture loop incremented `sentFrameCount` only after a post-send revision check, so a
  `stop()` landing in that window un-counted a frame that had genuinely reached the wire (a flaky
  native composition test, now fixed by counting on send success).
  **Still open on this goal:** receive/playback, and the live join/speak/hear/reconnect/leave
  evidence that remains operator-blocked. `mediaAdapterAvailability` is still `.unavailable` and
  the advertised DAVE version is still 0 — composition is not interoperability.
- **Receive/playback composition landed 2026-08-20 (`4a94cfe`), NOT connected.** Three
  worktree-isolated slices, each verified in isolation and merged clean: the media plane's
  receive entry point (AEAD open → DAVE unprotect → Opus decode, per-SSRC decoders created only
  after both AEAD and DAVE accept, so a spoofed-SSRC spray cannot grow memory); the portable
  receive loop; and a per-SSRC jitter buffer + PLC + saturating mixer. The buffer holds
  *protected* packets and releases them in sequence order — decoding on arrival would have been a
  silent correctness bug, since Opus decoder state is order-sensitive and `decodePacketLoss()`
  only means anything in-sequence.
  Verified: AbbeyCoreTests 403/403 in 34 suites, native gate 89 in 8 suites debug AND release,
  `NATIVE_MEDIA_SMOKE_GREEN`, `STATIC_SECURITY_GREEN`, all EXIT:0.
  **What this explicitly does NOT mean: no audio is heard.** Nothing calls the receive path in
  production. The plane needs `senderID` for DAVE's per-participant ratchet, which arrives on
  Speaking events, so an SSRC→user map has to exist before the loop can drive the plane — a
  design decision, not a shim. `mediaAdapterAvailability` stays `.unavailable` and the advertised
  DAVE version stays 0. Live evidence remains operator-blocked.
  One spec error was caught by an implementer rather than followed: "malformed framing is
  terminal" would have killed receive on the first normal RTCP receiver report, because Discord
  multiplexes RTP/RTX/RTCP on one socket. Corrected to: terminal only for unparseable framing
  claiming the audio payload type.
- **SSRC ownership landed 2026-08-20 (`a3635ba`) — half the receive wiring.** The receive path
  needs a `senderID` for DAVE's per-participant ratchet, and inbound Speaking (opcode 5) is the
  only place Discord sends `ssrc` and `user_id` together. The model already carried both fields;
  the session's inbound switch was dropping `.speaking` through `default: break`, decoding the
  information and discarding it. The session now records it, bounded at 256 and refusing new
  SSRCs when full rather than evicting arbitrarily, evicted per-user on Client Disconnect, and
  cleared in `clearEphemeralState` so no attribution survives into a later connection.
  Looking the SSRC up from an *unauthenticated* header is safe: a wrong answer cannot leak audio,
  it just fails that participant's ratchet and counts a drop. Both tests red-proved; restored
  source byte-identical by sha256. AbbeyCoreTests 405/405.
  **Gotcha worth remembering:** `senderID(forSSRC:)` must stay `async`. A non-`async` method does
  not win as the witness for an `async` protocol requirement, so the extension's nil default
  silently shadows it — no compile error, receive simply never learns a sender.
  **Still not end to end:** the adapter conforming the media plane to
  `DiscordVoiceAudioFrameDecoder` is the remaining seam. Nothing calls receive in production and
  no audio is heard.
- **Receive path connected end to end 2026-08-20 (`c2c1981`) — audio can now flow locally.**
  Three things blocked it, and only one was wiring.
  (a) **The availability gate was self-locking.** `mediaAdapterAvailability` was hardcoded
  `.unavailable`, `join()` refused `acceptsFrames` without `.fullyWired`, and
  `setReceiveEnabled(true)` then failed its guard — so no amount of receive code could produce
  sound. But `.fullyWired` also drives the advertised DAVE version, which must not be claimed
  without live evidence, which requires audio to work. Split into `.locallyComposed` (audio may
  flow here, DAVE still 0) and `.fullyWired` (that plus the wire claim). The snapshot reports
  both separately so "works locally" can never be read as "DAVE advertised".
  (b) **Wiring**: the factory takes an injected playback sink, binds the gateway to a local so
  the sender resolver closes over the *concrete* session (the existential would risk the
  protocol extension's nil default, and receive would never learn a sender — silently), and
  builds the receive loop over the same UDP session the send path uses.
  (c) **A defect in the playback sink written earlier the same day**: `AVAudioEngineAdapter.play`
  returns `false` for expected backpressure (deafened, or a queue-full it already counts) and
  throws only for a real refusal. The sink turned `false` into a throw, and the receive loop
  treats playback failure as terminal — so being deafened, or one transient queue-full, would
  have killed receive for the whole generation.
  Verified: native gate 94 tests in 9 suites debug AND release, `NATIVE_MEDIA_SMOKE_GREEN`,
  `STATIC_SECURITY_GREEN`, AbbeyCoreTests 405/405, AbbeyBotAppTests 77/77.
  **Still NOT proven — interoperability.** Nothing has run against Discord, the advertised DAVE
  version is still 0, and live evidence remains operator-blocked (verified this session: no
  `.env`, no token/guild in the environment, no Keychain entry).
  **Testing lesson recorded:** the first version of the new tests sat behind
  `#if canImport(AbbeyMediaNative)` in a target that does not link it, so they compiled out and
  "passed" without running. A guarded test in the wrong target is indistinguishable from a
  passing one.
- **Operator receive control landed 2026-08-20 — the audio path is now reachable end to end.**
  `MediaSessionModel.setReceiveEnabled(_:)` plus a `/voice` toggle, with `receiveActive` and
  `localMediaAvailable` surfaced in the app snapshot. Privacy posture is explicit in the UI copy:
  receiving decrypts and plays everyone else's audio, it is off until switched on, it is never
  started by joining, and it does not carry over to a new session. The toggle reads the
  controller's real state rather than an optimistic local flag, so a refused enable shows as
  still-off, and a refusal is *reported* instead of springing the switch back silently.
  Red-proved: swallowing the refusal fails the test; restored byte-identical by sha256.
  Verified: AbbeyCoreTests 405/405, AbbeyBotAppTests 79/79, AbbeyServerTests 22/22.
  **The honest boundary is unchanged and now the only thing left on this goal:** every layer is
  composed and gated, but nothing has run against Discord. The advertised DAVE version is still
  0, `mediaAdapterAvailability` reports `.locallyComposed` rather than `.fullyWired`, and live
  join/speak/hear/reconnect/leave evidence is operator-blocked — no token, guild, or Keychain
  entry exists in this environment. That last step needs a rotated bot token and an authorized
  test guild, which only Donald can supply.
- **Status → `blocked` 2026-08-20, and the last self-inflicted debt is paid.** Two things closed
  this pass, neither of them new capability.
  (a) **The verification gap left open in `048d57c` is closed.** That commit was pushed with its
  message stating plainly that the native gate had NOT been run on it — the first attempt was
  killed (exit 137, memory pressure) and the retry was declined. The gate has now been run on
  that exact tree: `NATIVE_MEDIA_SMOKE_GREEN`, `STATIC_SECURITY_GREEN`, 94 tests in 9 suites
  passing in **debug and release**, `NATIVE_GATE_EXIT: 0`. The commit message's caveat is now
  historical rather than live.
  (b) **`f2f8fd2` shares the terminal-disposition decision between the capture and receive
  lanes** — the last open finding from the strict review that did not require widening access on
  key-holding code. See that commit for the red-proof.
  **Why `blocked` and not `in_progress`:** every checklist item that code can close is closed and
  gated. What remains is item 12 alone — a live join/speak/hear/reconnect/leave run — and it is
  operator-blocked, not code-blocked: re-verified this session that no `.env`, no
  `DISCORD_BOT_TOKEN`/`DISCORD_DEV_GUILD_ID`, and no Keychain entry exist here. `in_progress`
  implied someone was still grinding on it; `blocked` says correctly that the ball is in Donald's
  court. The advertised DAVE version stays `0` and `mediaAdapterAvailability` stays
  `.locallyComposed`, exactly as before — **composition is still not interoperability, and
  nothing in this pass moved that line.**
  **Two review findings are deliberately left open, not quietly dropped:**
  `DiscordVoiceNativeMediaPlane.swift` (1266 lines) and `DiscordVoiceController.swift` (1303 —
  the dedup traded lines for shared logic plus its rationale). Decomposing the plane is not
  cleanup: Swift's `private` is file-scoped, so splitting it means **widening visibility on the
  code that owns the AEAD keys and DAVE sessions**. That is a security-posture change wearing a
  refactor's clothes, on the one file whose last restructuring silently reintroduced two
  just-fixed bugs. It needs its own deliberate decision, not the tail end of a long session.

## Complete Discord video and Go Live
status: blocked
blocked-on: the same live-Discord verification as the voice goal — specifically, observing which
video codec Discord actually negotiates and on what field it arrives.
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
- **Video send-boundary composition 2026-08-20 (extends audio Phase 5 to `.video`):**
  `DiscordVoiceNativeMediaPlane.sendVideoFrame(encodedFrame:)` now composes the same protected
  send path the audio Phase 5 slice proved, for one already-encoded video frame: the installed
  `NativeDAVESession.protect(...)` with the video frame type and negotiated codec label, a
  90 kHz `DiscordVoiceVideoRTPClock`, the negotiated video RTP payload type with the marker bit
  set on the frame boundary, the shared single-owner `DiscordVoiceTransportEncryption` AEAD
  counter, and the retained UDP transport. `installVideoSource(...)` binds a video SSRC only
  from the existing bounded Ready allocation models (`VoiceGatewayV8VideoSSRCAllocation`) —
  clients never invent SSRCs — and `DiscordVoiceGatewaySession` now sends the real Opcode 12
  announcement through `machine.videoAnnouncement(_:)` (validated against Ready) exactly once
  before the first video packet, the announcement-before-media analogue of Speaking. Fail-closed
  everywhere: no DAVE attestation → no video source and no send; missing/failed announcement
  callback, empty frames, foreign allocations, unmapped codecs (Opus/H.265), protect failures,
  and reset-mid-send all throw with nothing reaching the socket, proven by one composition test
  and eight dedicated fail-closed tests mirroring the audio Phase 5 style. **This closes the
  outbound video send-path composition boundary only.** Nothing in production calls
  `sendVideoFrame`; there is no camera/screen capture wiring into it, no video encoder, no
  completed codec negotiation, no packetization/pacing/RTX, no receive/render path, no
  congestion/fault/perf coverage, and no live camera or Go Live evidence — no capability
  advertisement changed. The goal remains `in_progress`.
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

- **Integrated onto the branch 2026-08-20 ~06:30, with one correction.** The video send slice was
  merged into `codex/discord-voice-phase4` (conflicts were in the media plane, where the audio
  review fixes had landed in parallel). Reviewing the merged result surfaced that the new video
  path had faithfully copied the audio path's *pre-fix* shape and so reintroduced both bugs the
  review had just closed: the Opcode 12 announcement latched its one-shot flag before the callback
  ran, and the video datagram send was untracked by `reset()`. Audio and video now share one
  `OneShotSignalGate` (with a documented per-kind difference: a missing Opcode 12 callback fails
  closed, a missing Speaking callback does not) and one `sendTracked` path, specifically so the
  two cannot diverge again. Still the send boundary only — no capture, codec negotiation,
  packetization, rendering, or live evidence; no capability advertisement changed.
- **Packetization + negotiation landed 2026-08-20 (`3ebce81`), not adopted by the send path.**
  `DiscordVoiceVideoPacketizer` fixes a real wire bug — the RTP marker bit was unconditionally
  `true`, which is incorrect for any frame above MTU. Now one shared timestamp per frame,
  contiguous sequence numbers, marker on the final fragment only, with MTU (1200) measured on the
  *sealed* datagram and the AEAD's exact 20-byte expansion subtracted from every fragment budget.
  **The spec's negotiation premise was wrong and the implementer refused to paper over it:**
  neither Ready nor Session Description carries any codec field (verified — zero repo-wide hits
  for `video_codec|audio_codec|payload_type`). Rather than invent a CodingKey for a field nobody
  has observed on the wire, `DiscordVoiceVideoCodecNegotiation` fails closed; its only reachable
  input today is `nil` → throws, which is the correct state, because no codec is negotiated so no
  video may be sent. **Where the negotiated codec name actually arrives is now an open question
  requiring live verification, not an assumption baked into code.**
  Still open: `sendVideoFrame` emits one packet per frame (adoption needs a `NativeDAVECodec`
  bridge + per-fragment revision re-check) **[SUPERSEDED 2026-08-20 — `27dff85` adopted the
  packetizer: `sendVideoFrame` now calls `makeVideoPacketizer().packetize(...)` and re-checks
  both the generation and the video-source revision after every fragment, so a source swap
  mid-frame cannot put the remaining fragments on the wire under the obsolete SSRC. Left in
  place as the historical record, annotated so nobody stops reading here.]**, and fragments are
  opaque byte ranges — no H.264 FU-A, VP8 descriptor, or AV1 OBU header, so no receiver
  interoperability is claimed.
- **Status → `blocked` 2026-08-20.** Both remaining items reduce to one unblocker, which is why
  this is no longer `in_progress`.
  **Codec negotiation** is live-blocked outright: `DiscordVoiceVideoCodecNegotiation` documents
  that neither `VoiceGatewayV8Ready` nor `VoiceGatewayV8SessionDescription` carries a codec name
  or payload type, so `resolve` can only ever be handed `nil` today, and `nil` throws. That is
  the intended state — no codec is negotiated, so no video may be sent.
  **Payload descriptors** (H.264 FU-A, VP8 descriptor, AV1 OBU header) are a closer call, and the
  reasoning is recorded rather than assumed. They are *not* barred by the precedent that stopped
  us inventing a `video_codec` CodingKey: that precedent is about unobserved **Discord-proprietary**
  wire shapes, whereas RTP payload formats are published IETF standards and could be implemented
  from a normative source. What blocks them is different and stronger — **which** descriptor to
  build is determined by which codec is negotiated, and that is exactly the unknown above. Building
  one now would mean guessing the codec, then shipping the result beneath a `resolve` that cannot
  execute: dead code whose correctness could never be observed.
  So the honest ordering is: live verification first, descriptor second. No capability
  advertisement moved, and no video path in this repository works.

## Cross-platform server-graph toolchain parity (swiftly snapshot)
status: done
- Goal: local development gets a first-class swiftly-managed Swift 6.4/6.5 development-snapshot
  path for the server graph (AbbeyCore/AbbeyServerKit/AbbeyServer/AbbeyCLI under
  `ABBEY_PACKAGE_ROLE=server`), matching CI's `swiftlang/swift:nightly-6.4.x-bookworm` Linux image
  — WITHOUT disturbing the desktop's Xcode toolchain path (`.swift-version` stays `xcode`; SwiftData
  macros break under snapshot toolchains, so the swiftly selection is per-invocation only, never
  the global default).
- Acceptance: a committed `Scripts/check-server-snapshot.sh` that resolves/builds/tests the four CI
  server suites under the snapshot with real per-gate exit codes, AGENTS.md documenting the path,
  and the Xcode desktop build still green.
- **Landed 2026-08-20 (commits on the branch).** `Scripts/check-server-snapshot.sh` builds and
  tests the server graph under a swiftly-selected development snapshot (`main-snapshot-2026-08-11`,
  6.5-dev), per-invocation only — the swiftly global default is untouched. Measured: resolve/build
  exit 0; AbbeyCoreTests 302, AbbeyCLITests 30, AbbeyServerKitTests 117, AbbeyServerTests 22, all
  exit 0, `SERVER_SNAPSHOT_GREEN`, with no source changes needed for the newer toolchain. The Xcode
  desktop path stayed green (3622/3622 targets). `.swift-version` is now gitignored and untracked:
  `xcode` is a macOS-only swiftly selector that breaks every proxied `swift` invocation on Linux
  (the review's P1). **Honest limit:** this runs a 6.5-dev snapshot on Darwin against the Xcode
  SDK, while CI runs Linux glibc/Foundation in a nightly-6.4.x image — it is toolchain parity, not
  platform parity, and it cannot catch Linux-only breakage. The very next CI run proved that: the
  `FoundationNetworking` failure was invisible to this gate. Docker/Linux remains the only real
  check for that class.
- **Closed 2026-08-20.** Every acceptance criterion is met and verified on `main`:
  `Scripts/check-server-snapshot.sh` present and executable, AGENTS.md documents the path,
  `.swift-version` gitignored and untracked, Xcode desktop build still green (3622/3622 targets).
  Scope note so this is not over-read later: this goal was always *toolchain* parity and delivered
  exactly that. It is explicitly NOT platform parity and cannot catch Linux-only breakage — which
  is why "Make the Linux CI job actually pass" is a separate, still-open goal.

## Make the Linux CI job actually pass
status: done
caveat: closed on one green run (32415037815). A Linux-only FLAKE surfaced two commits later
(32427615181) and is fixed below — the job is green, but "green once" was never the same claim as
"reliably green", and this entry should not have read as if it were.
- **Linux flake found and fixed 2026-08-20.** `protocolZeroStagesUpgradeUntilExecute` failed on
  Linux (`upgraded.dave` / `upgraded.isProductionReady` both false) on `9f347f6`. It is a **test**
  defect, not a product regression, and the evidence says so from three directions: `9f347f6`
  touched only the controller, the media plane (not compiled on Linux), and receive tests — it
  cannot have changed `DiscordVoiceGatewaySession`; the test passes on macOS; and `048d57c`, one
  commit later on the identical gateway code, passed Linux (run 32428530569).
  The defect is an unsound synchronization point: the test waited on
  `handler.receivedOpcodes().count == 3` — the *handler's* observation — then read the session's
  own `lastCapabilities`. Those are two different moments, and nothing orders them. The 32 test
  lines `9f347f6` added perturbed scheduling enough to expose it. It now waits on the capability
  itself.
  **Honest limit of the local proof:** macOS cannot red-prove a Linux scheduling race — the broken
  version passes here too. What was proved instead is that the new wait is not vacuous:
  suppressing the Execute Transition makes it time out rather than pass. Restored byte-identical
  by sha256 (ce6fc3c7...); AbbeyCoreTests 406/406. Confirmation that the flake is gone can only
  come from Linux CI.
- **Discovered 2026-08-20:** the `Abbey CI` linux job has **not succeeded in any of the last 30
  runs, on any branch, including `main`.** It is not a regression from any one PR — the server
  graph (`ABBEY_PACKAGE_ROLE=server`: AbbeyCore/AbbeyServerKit/AbbeyServer/AbbeyCLI) simply does
  not build on Linux, and each fix only reveals the next break, because the compiler stops at the
  first failing file.
- Fixed this pass, all the same class (Darwin re-exports or provides something Linux does not):
  `RemoteOpenAICompatibleProvider` needed `#if canImport(FoundationNetworking)` for `URLSession`;
  `EngineMetrics` needed an explicit `import Observation` for `@Observable`; `TwitchBridge`'s
  CFStream/CFNetwork TLS path is Darwin-only and is now `#if canImport(Darwin)`-guarded, failing
  closed on Linux rather than falling back to plaintext IRC.
- A full audit of the server graph for this class is now clean: no unguarded Darwin-only framework
  imports, no unguarded `CF*`/`kCF*`/`Unmanaged`/`@objc` users, no `DispatchQueue` users missing
  `import Dispatch`. `AppConfig.swift`'s `#if canImport(Security)` Keychain guard is the pattern
  the other fixes follow.
- **2026-08-20 second pass — 6th break, and the lint that should have caught it.** CI found
  `SOCK_STREAM` passed straight to `socket(_:_:_:)`: glibc types it as the `__socket_type` enum,
  Darwin and musl as a plain `Int32`. It compiled locally, compiled under the new musl Linux
  gate, AND passed review — glibc CI was the only thing that saw it. **That is now twice** the
  musl gate has been green while a real glibc break was live (the first was the `stderr` global).
  Both classes are now in `check-server-linux.sh`'s `glibc-divergence` lint, which was validated
  by firing in both directions (reverted fix → exit 1 naming the line; fixed → exit 0), with a
  visible `// glibc-divergence:ok` opt-out for deliberate non-Glibc branches.
  **The standing lesson:** a green musl cross-build is evidence about *musl*. Treat every new
  libc-adjacent construct as unproven for glibc until either the lint covers it or CI says so.
- **DONE 2026-08-20 — acceptance met and OBSERVED, not inferred.** Run `32415037815` on
  `caa1697` is `success`: AbbeyCoreTests 406/406, AbbeyCLITests 30/30, AbbeyServerKitTests
  117/117, AbbeyServerTests 22/22, all on Linux. First green in this job's recorded history.
  The last blocker was not the missing Leaf route (that was `252c08c`, which fixed macOS only
  and left Linux red — a macOS-green result mistakenly reported as done). The real cause was
  bundle-path resolution: every server path came from
  `Bundle.module.resourceURL ?? bundleURL` + "Resources", a claim never tested on Linux, and
  three things hid a wrong answer — `configure.swift` CREATED the missing public directory,
  Leaf failed only at render time as a bare 500, and CI asserted `index.html` in the SOURCE
  tree rather than the built bundle. Now the resources root is found by probing candidates for
  one that exists, startup throws `AbbeyServerResourceError` naming every path it looked in,
  and the failing assertion carries the status and body so the CI log can diagnose itself.
- **Standing caveat, unchanged:** a green musl cross-build is evidence about musl only. Twice
  this session it was green while a real glibc break was live. `check-server-linux.sh` covers
  the product graph and cannot compile tests at all; CI remains the only authority.
- **Acceptance:** one green linux run. Not claimable until observed — a clean audit is not a
  passing build, and this job has proven it hides breakage one file at a time.
- **Known gap in local tooling:** `Scripts/check-server-snapshot.sh` gives toolchain parity on
  Darwin, not platform parity, so it cannot catch this class at all (it did not catch any of the
  three). The only real pre-flight is a Linux build. There is no container runtime on this machine
  (no docker/colima/podman) and the Swift static-Linux SDK URL tried for 6.3.2 returned 404, so
  every fix currently costs one ~18-minute CI round trip. Worth solving before the next Linux
  push: either install a container runtime or find the correct static-SDK artifact.
- **Product decision surfaced, needs Donald:** Twitch IRC now explicitly does not work on Linux.
  If the server is meant to run Twitch IRC on Linux, that needs a NIOSSL-based client (the repo
  already depends on swift-nio-ssl) — a real piece of work, deliberately not bolted into a voice PR.

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

## Align every agent-guidance mirror with disk
status: done
- Successor to the CLAUDE.md alignment goal below, widened to the four mirrors named in
  `AGENTS.md` -> Workflow. Verified 2026-09-16 that all twelve paths `CLAUDE.md` routes to exist,
  that its gate ordering matches `Scripts/verify-all.sh` line for line, and that the
  `ABBEY_PACKAGE_ROLE` / `ABBEY_NATIVE_MEDIA` / `ABBEY_HAS_DESKTOP` knobs match `Package.swift`.
  `CLAUDE.md` stays a routing index; no gate list was duplicated into it.
- Three defects found and fixed, each verified against the tree rather than inferred:
  1. `.codex/agents/abbey.toml` located the package at `~/Desktop/AbbeyBot`, **a path that does
     not exist**; every absolute instruction in that mirror was dead. Now `~/dev/active/AbbeyBot`,
     matching the `.cursor` mirror. Its build-path rule lost the stale Desktop/iCloud framing too.
  2. `.agents/skills/abbey-verify/SKILL.md` step 6 read "`AGENTS.md`, `AGENTS.md`" — a find/replace
     artifact that erased `CLAUDE.md` from the drift-correction list, so the `.agents` mirror told
     agents to skip the one file the `.claude` mirror told them to fix. The two skill copies are
     now byte-identical.
  3. Both agent mirrors said "Swift 6.4 language mode". `Package.swift` pins tools 6.4 with
     `.swiftLanguageMode(.v6)` on every target; corrected in both.
- Three gaps closed: `Scripts/check-release-container.sh` (a seven-stage Docker gate) and `.github/workflows/release-images.yml`
  were undocumented everywhere (the script is invoked only from that workflow, which also runs
  `deploy/production/tests/run.sh` and is the sole source of GHCR image evidence) and are now in
  `AGENTS.md` -> Additional Gates plus the `CLAUDE.md` deployment row; `AbbeyQuasarKit` was absent
  from both agent mirrors despite owning a separate `ABBEY_QUASAR_API_TOKEN` policy, the bounded
  path guard, the single-writer registry, and rollback integrity; and the mirrors' gate menus were
  missing package-graph, knowledge-snapshot, Linux-parity, native-media, and release-container.
- README's Layout block claimed the entry dispatches `desktop | serve | cli`;
  `Sources/AbbeyEntry/main.swift:22` also dispatches `quasar [serve]`. Layout now also names the
  two media targets, the three C shims, `Contracts/`, `web/`, and `functions/`.
- Verified: `bash Scripts/check-static-security.sh` exit 0 with in-log `STATIC_SECURITY_GREEN`
  (exit code read from the command, not a pipeline tail). Documentation-only change touching no
  Swift, web, or deploy source, so no smoke or `verify-all.sh` run is claimed. Branch protection on
  this private repo is not readable with the available token, so "required check" is asserted
  nowhere; `release-images.yml` is described only by its `on:` triggers.
- Committed on `cursor/command-surface-truth-20260916`, not on `main`: this repository routes
  changes through `cursor/*` or `codex/*` review branches, never a direct commit on `main`. Not
  pushed and no PR opened.

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

## Release container publishes from main
status: done

`Release container images` had never passed on `main`. The workflow arrived with
`1d499d4` on `cursor/quasar-completion-20260906`, and that branch was still
iterating on container staging (`e69d0ff`, `aae40b4`) when the branch was merged
and deleted on 2026-09-06, so the job landed unfinished rather than regressed.

- **Root cause, fixed at `cc0369c`.** The runtime stage did
  `COPY --from=build /usr/lib/swift/linux`. That directory does not exist in
  `swiftlang/swift:nightly-6.4.x-bookworm`; BuildKit reported only "not found",
  after a 32-minute build that had otherwise succeeded and staged its products.
  Staging now happens in the build stage, where a shell can look, and the path is
  discovered rather than assumed: `ldd` on the staged executable first (the
  directory the linker resolved `libswiftCore.so` from is correct by definition),
  then `swiftc -print-target-info`, then known image layouts. The result is copied
  to a fixed `/stage-runtime`, so the runtime stage's COPY no longer depends on
  the toolchain image's layout; `LD_LIBRARY_PATH` is unchanged.
- **The real layout is `/opt/swift/6.2/usr/lib/swift/linux`** (reported by the
  `cc0369c` build, not guessed here). It is now also in the fallback candidates
  and the failure diagnostic's search roots.
- **`cc0369c` fixed the container and failed on its own test.** The image built,
  staged and exported; the publish job then failed in
  `test_swift_runtime_staging.py`, whose fake `swiftc` built JSON with `printf`
  and escaped quotes. `/bin/sh` is bash on macOS and dash on Debian and their
  `printf` disagree about backslash escapes, so the runner's shim emitted literal
  backslashes. Fixed at `fbc1d35`: shim output is written from Python and read
  back with `cat`, so the shim source carries no backslashes for any shell to
  reinterpret. This is the same class as the two Windows test defects fixed in
  `abbey-bot` the same morning, and it recurred inside the fix for it.
- Local evidence at `fbc1d35`: 23 release-container tests, shellcheck clean,
  `Scripts/verify-all.sh` green. `Abbey CI` green on `cc0369c`.
- **`fbc1d35` proved the container half.** The publish job reached
  `1/7 build release images` and `2/7 assert runtime and bundled resources`
  green: the image builds, the discovered runtime is present and correct, the
  bundled resources assert, and the 23 staging tests pass on the Linux runner.
  It now fails at `3/7 boot full server with disposable SQLite`. The server
  boots and answers `/health`, then `POST /api/sites` returns HTTP 500 and the
  workspace is archived as `failed-<uuid>-release-manager-fixture`. That is the
  Quasar site-creation path the merged branch was still building, not a
  packaging defect.
- **`642f8fd` makes that failure legible.** Only the readiness probes called
  `docker logs`, so the 500 arrived with no server-side cause anywhere in a
  35-minute run. The cleanup trap now dumps every gate container's log tail
  whenever the script exits non-zero, covering stages 3 through 7.
- **Not established:** the published image itself, and the site-creation path
  behind the 500. There is no Docker CLI on the development host, so every
  container claim here is CI-only and each iteration costs a full build; the
  `container-gate` job has been `skipped` on every run because `publish` never
  succeeded. Next slice: read the server log the `642f8fd` run now emits and fix
  the site-creation failure. The goal closes when `Release container images`
  completes green on an exact `main` SHA.

### GREEN on `5e2162a` (2026-09-06 23:55 UTC)

`Release container images` passed for the first time. All seven stages ran:
build, runtime/bundled-resource assertions, server boot on disposable SQLite,
restart against persisted state, packaged Quasar scaffold prepare/render,
scaffold restart, and production Caddy routing. `RELEASE CONTAINER GREEN`, with
`QUASAR_MANAGER_CREATE_GREEN`, `QUASAR_MANAGER_RESTART_GREEN`,
`CADDY_PROXY_FIXTURE_GREEN` and `RESTORE_CONTAINER_GREEN` (real PostgreSQL,
three-store rollback, corrupt-dump refusal, encrypted restic retrieval).

Four defects, each hidden by the one before it and each first reachable only
once the gate cleared the previous:

1. `a027502` -- `QuasarScaffolder` copies the packaged template with
   `FileManager.copyItem`, which preserves ownership on Linux. As uid 10001
   against root-owned bundle files that chown is EPERM, so every site creation
   failed. Darwin does not chown on copy, so it was unreachable locally.
2. `64fcd1f` -- the packaged `next-site/bun.lock` has been `lockfileVersion: 2`
   since its first commit while Bun was pinned to 1.3.14, which reads only
   version 1. The pin moved instead of the lockfile, leaving dependency
   resolution byte-identical.
3. `c423426` -- `caddy adapt --validate` provisions the config, so the 29-char
   placeholder failed caddy-dns/cloudflare's `^[A-Za-z0-9_-]{35,50}$`. Still a
   fake token; no credential was introduced.
4. `5e2162a` -- `proxy-check.py` did `import http.client` then `def http(...)`,
   so the function shadowed the module and stage 7 could never have run.

What made this tractable was `46d1f92`: `mapQuasarError`'s catch-all told
operators to read logs it never wrote, so the failure was a bare 500 with no
cause anywhere and each guess cost a full container build. Once it logged, the
next run named the exact `NSSourceFilePathErrorKey` and the rest was mechanical.

`container-gate` shows `skipped` on main **by design** --
`if: github.event_name == 'pull_request' || github.ref != 'refs/heads/main'` --
so it is not an outstanding gap. An earlier note here implying otherwise was
wrong.

Note for future runs: `AbbeyCoreTests` is timing-flaky on the Linux runner.
`64fcd1f` failed on three structured-inference cancellation tests and passed on
re-run of identical code; `c423426` failed on a different DAVE-heartbeat test
with `.conditionTimedOut` and also passed on re-run. A different test each time,
all timeout-based, unrelated to any change here.

## Improve the Discord command surface and the macOS UI
status: in_progress
- Captured 2026-09-16 from a pasted capability blurb: "perform broad automation like creating
  roles, custom slash commands, or sending DMs … remembering facts … switching my persona …
  looking up specific information … head over to help commands".
- **The blurb is not this repository's copy, and three of its claims have no implementation
  here.** It appears nowhere in `Sources/`, `Contracts/`, or `web/`. Searched for the capability,
  not the wording: there is no `createRole` / `addRole` / role-permission call, no
  `createDM` / DM-channel send, and no runtime command creation — `CommandSpec.all` is a compiled
  constant that `CommandRegistry.register` pushes to Discord, so a user cannot author a slash
  command. The other three claims are real: `/remember` `/forget` `/facts`, `/persona`, and
  `/knowledge`. Do not adopt that blurb as `/help` copy; three lines of it would be overclaims of
  exactly the kind this goal's sibling above exists to remove.
- Slice delivered: **`/help` was the sixth uncrosschecked list of command identity.**
  `CommandSpec`'s own doc comment calls `all` the single source of truth "rather than re-listed
  per call site", while `DiscordSlashLogic.helpText()` re-listed all nineteen commands as a
  hand-maintained string literal with nothing binding the two. They happened to agree when
  measured, so this is a latent defect closed, not a bug fixed — say so rather than claiming a
  user-visible repair. Failure modes it removes: register a command and forget the literal, and it
  is invisible to everyone who runs `/help`; delete one and forget the literal, and `/help`
  advertises something that answers "Unknown command".
- `/help` is now derived from `CommandSpec.all` via `CommandSpec.helpText`, so its descriptions are
  by construction the same strings Discord registers and shows in its own command picker.
- Genuinely new information for users, not just a refactor: `helpLine` derives its markers from the
  same `visibility` and `defaultMemberPermissions` that authorization reads, so `/persona` and
  `/model` now render "operator only, private reply". The literal said neither, so a member read
  the same list as an operator and learned the difference only by being refused.
- Verified: five new `HelpTextRegistryTests` (every registered command advertised; nothing
  unregistered advertised; descriptions match; the operator/private markers present on `/persona`
  and absent on the open `/ask`; the rendered text fits inside the router's 1900-character reply
  clip, which a derived list can now overflow as commands are added). **Mutation-tested rather
  than trusted**: dropping one command from the derived list fails the suite with "/help omits
  /voice", exit 1, and the source was restored from a pre-mutation copy. Full `AbbeyCoreTests`
  491 tests in 44 suites, exit 0 read from the command, not a pipeline tail.
- **Fixed: the macOS UI stated the wrong command set, and it
  states it next to the button that performs registration.** `DiscordView.swift:141` renders
  `Text("Commands: ask, rep, remember, forget, context, persona, voice")` under "Register slash
  commands". `CommandSpec.all` registers **nineteen**; that caption names **seven**. Missing:
  equity, explain, facts, help, industry, knowledge, mod, model, ping, quasar, status, summarize.
  Unlike the `/help` literal, this one is not latent — it is wrong today, and an operator pressing
  that button cannot see from the UI what is about to be published to their guild. It was the
  seventh copy of command identity. The caption is now a `DisclosureGroup` over `CommandSpec.all`
  showing each command's name, its registered description, and its audience markers. The marker
  logic moved to a shared `CommandSpec.audienceNotes` rather than being written a second time in
  the view, which would have recreated the exact drift this slice removes.
- **Fixed: almost nothing grounded the model's own description of what it can do.** The
  pasted blurb is first-person model output, and its three false claims are unconstrained
  invention rather than stale copy. `PersonaProtocol.respond` assembles the prompt from
  `systemPrompt` + industry suffix + channel summary + user facts + retrieved evidence, and injects
  **no capability manifest and no command list**. Each persona carries exactly one narrow
  anti-overclaim rule — Abbey "do not invent compliance certifications", Aviva "do not claim
  external engines or throughput metrics you do not have", Abi "do not invent legal
  certifications" — and none of them constrains capability claims. **Correction to an earlier
  reading in this same session: "nothing grounds it" was too broad.** `BotRuntime.modAdvice`
  already prepends "Moderation advice only — do not claim you executed kicks, bans, or purges",
  but only for `/mod`. `/ask`, `/explain` and ordinary ingest all take the ungrounded path, which
  is the one a "what can you do" question lands on.
- Fix: `CommandSpec.capabilityManifest` is derived from `all` and injected by
  `PersonaProtocol.respond`, so it cannot fall behind the commands it describes and every persona
  inherits it. Each denial was checked against the tree first rather than assumed: no role call,
  no DM-channel creation, and `all` is a compiled constant `CommandRegistry.register` pushes. The
  kick/ban clause is deliberately the weaker "do not claim you executed", mirroring `modAdvice`,
  because `ModerationClient.kick`/`ban` **do** exist behind `ConfirmationGate` — writing "cannot
  kick" would have replaced one false claim with another.
- Verified: four `CapabilityManifestTests`, including an end-to-end assertion that drives
  `AbbeyPersona`/`AvivaPersona`/`AbiPersona` through an `InferenceRouter` with a capturing
  provider and reads the manifest out of the prompt the model was actually handed. Mutation-tested:
  removing the injection fails with "Abbey is ungrounded", "Aviva is ungrounded", "Abi is
  ungrounded" and "manifest did not reach the model", exit 1; source restored from a pre-mutation
  copy.
- The macOS half is addressed only for the command panel. `Sources/AbbeyBotApp/Views/` holds
  thirteen views; no broader UI work was done and none is claimed.
- Committed on `cursor/command-surface-truth-20260916`: code in `92dcf5c`, documentation and this
  ledger in the commit that follows it. Not pushed and no PR opened. **This bullet and its sibling
  above previously said "uncommitted, on `main`" — true when written, false once the branch
  landed, which is the same defect corrected earlier in this file for four slices that stayed
  marked "(uncommitted)" after landing in `e679011`.** A status line about where work lives is
  stale the moment the work moves; re-read it before committing the file that carries it.
- Correction 2026-09-16 12:3x EDT: the bullet above saying "Not pushed and no PR opened" is
  stale. The branch was rebased cleanly onto `0de3c14` (PR #89) and opened as PR #90; it was
  re-gated there together with the test-hygiene follow-up below rather than on its 03:36 green.

## Redesign the Discord command, persona, and floor surfaces for claim honesty
status: in_progress
- Scope: the Discord-facing contracts in `AbbeyCore` — command registration/authorization/visibility, intent classification, persona routing copy, and the deterministic floor. Acceptance bar is this repo's own claims discipline: a name, description, or mode must match what the code does.
- Command-contract slice implemented 2026-09-09, **landed** in `e679011` via PR #88 (`3b1c281`): command identity was a bare `String` replicated across five uncrosschecked lists — `CommandRegistry.all`, the router's ephemerality switch, the router's `mutatesGlobalState` chain, the router's dispatch switch, and the access policy's user-scoped switch. Omissions failed silently in the unsafe direction: a missing mutation entry leaves a guild-mutating command runnable by anyone; a missing ephemerality entry publishes stored personal facts into the channel. New `CommandSpec` declares name, options, scope, and visibility together; the registry derives its payloads from it and the router/policy read it. `/model` keeps a `globalStateWhenOptionPresent("mode")` scope so the bare read form stays available to everyone. `VERIFY-ALL GREEN`, 885 tests / 89 suites, exit 0.
- Worth keeping from that slice: the first attempt added `isUserScoped` as a caller-supplied field defaulting to `false`, which recreated the same drift risk one layer up. The pre-existing `commandAccessScopesMemoryAndGlobalMutations` test failed and was right to. Scope is a property of the command, not of the request, so `DiscordCommandAccessPolicy` now reads it from `CommandSpec` and no caller can forget it.
- Intent-classifier slice implemented, **landed** in `e679011`: `classifyLoose` matched keywords with bare `contains`, so "reply", "report", "prepare" and "represent" classified as `.repQuery`, and "banana", "kickoff", "urban" and "abandon" as `.modRequest`. This corrupted state rather than only picking a wrong reply: `Intent.quality` feeds `recordInteraction` and the DQN reward, so "that is a banana" wrote moderation-grade 0.8 quality into reputation and the replay buffer. Fixed with whole-word matching, following the `\b`-anchored persona rule three lines below it. Verified by mutation: reverting to `contains` fails all five new regression tests on those literal strings.
- Floor-provider slice implemented, **landed** in `e679011`: `DeterministicFloorProvider` — named deterministic, reporting `mode: .deterministicFloor` — selected acknowledgements with `randomElement()`, the only `randomElement()` in `Sources/`. Same input, different reply, on the path that holds when every model is unavailable; the existing test covered only the fixed greeting branch, which is why it survived. Now derived from the request with FNV-1a. Deliberately not `hashValue`: Swift seeds `Hasher` per process, so that fix would pass in-process and fail across runs. Its doc comment claimed template banks "keyed by persona register"; the banks are keyed by intent and `generate` never reads `systemPrompt`, so all three personas emit byte-identical floor text. That limitation is now documented and pinned by a test rather than smoothed over. `VERIFY-ALL GREEN`, 486 tests, exit 0.
- Persona-panel copy corrected, **landed** in `e679011`: `PersonaSwitcherView` told operators its test prompt "uses the active persona and the same reply-cooldown rules as live Discord". The cooldown half was true; the persona half was not — the panel calls `currentPersona()` while live Discord calls `route(intent:userText:)` per message, so the two disagree for every question, greeting, mod request, and small talk. Copy now states which persona it uses and that live Discord may differ. Behaviour deliberately unchanged: testing the selected persona is a reasonable intent for a persona switcher, so the claim was the defect, not the call.
- Ledger drift corrected 2026-09-16: the four slices above were still marked "(uncommitted)" long after they landed. Re-verified against `HEAD`, not against this file: `Sources/AbbeyCore/Discord/CommandSpec.swift` exists; `IntentClassifier.classifyLoose` now matches through `containsWord` rather than bare `contains`; `DeterministicFloorProvider` derives its acknowledgement with FNV-1a and the only remaining `randomElement` token in `Sources/` is the doc comment recording what was replaced; `PersonaSwitcherView` states that live Discord picks a persona per message. All four are in `e679011`, merged as PR #88. The goal stays `in_progress` because the four items below are open by decision, not by omission.
- Open, and NOT changed because they are Donald's decisions rather than cleanups: `ConfirmationGate.request` is `guard requireConfirmation() else { return true }`, so `ABBEY_CONFIRMATION_REQUIRED=false` turns the human gate into a pass-through on the only path that can kick or ban (no test covers that branch); and the `facts: [String]` store has no count cap, length cap, TTL, or eviction — the one unbounded store in a codebase that bounds its DQN replay buffer to 10,000.
- Open, unverified claim needing a decision rather than a guess: `/ask` registers as "Ask Abbey" but always routes `.question` to Aviva. "Abbey" may mean the product (the status embed says "AbbeyBot"), so this may be correct copy rather than a defect. Not touched.
- Open: the REST surface (`POST /api/state/remember|forget`) takes `userId`/`guildId` from the request body behind a single shared bearer token, with no per-user check — an operator-trust model, unlike the Discord slash path which is properly self-or-moderator gated. Worth naming as a deliberate difference or closing it.

- Slice 2026-09-16 13:2x EDT, `ConfirmationGate` bypass branch (still no decision taken on
  whether the bypass should exist): with confirmation off, `request` published
  `.destructiveActionRequested` and approved, but never `.destructiveActionConfirmed`. The kick,
  ban or purge still ran, yet `AbbeyEngine.handle` never counted it in
  `metrics.recordDestructiveAction` and the delayed-reward design's moderation reward never
  applied. The bypass now also publishes `.destructiveActionConfirmed`. Pinned by
  `ConfirmationGateTests` (event sequence for both branches, empty queue on bypass) and
  `AbbeyEngineModerationRewardTests.unconfirmedKickStillRewardsTheTargetsSamples`.
  Mutation-tested: removing the new publish fails both, exit 1; source restored from a
  pre-mutation copy. The design doc's "no confirmation event, no reward" note was updated.
- Same slice, a claim-honesty fix: Settings labelled six keys "Env:" that `AppConfig` reads
  only from UserDefaults (`ABBEY_OPERATING_MODE`, `ABBEY_REPLY_COOLDOWN_SECONDS`,
  `ABBEY_MEMORY_CONSOLIDATION_INTERVAL_MIN`, `ABBEY_REPUTATION_DECAY`,
  `ABBEY_CONFIRMATION_REQUIRED`, `ABBEY_EQUITY_MODULE_ENABLED`). They now read
  "UserDefaults key:", pinned by `AppConfigEnvironmentScopeTests`. Making any of them honour the
  environment was deliberately not done: for `ABBEY_CONFIRMATION_REQUIRED` it would widen the
  bypass, which is the open decision above.
- Decisions taken 2026-09-16 13:4x EDT (Donald, via the four-question prompt), all landed
  in one slice: (1) kick and ban always wait for the confirmation sheet; only purge honours
  the confirmation-off setting (`DestructiveAction.alwaysRequiresConfirmation`, checked in
  `ConfirmationGate.request`; Settings caption rewritten). (2) Remembered facts are bounded by
  a shared `MemoryFactPolicy`: 50 per user, 280 characters, oldest evicted, applied by both
  `MemoryRepository.appendFact` and `AbbeyEngine.appendMemoryFact`; `/remember` reports a cut
  or a drop; sync still copies rows verbatim and a legacy oversize row trims on its next append.
  (3) `/ask`'s "Ask Abbey" names the product; a comment on `CommandSpec` records it and the
  copy is unchanged. (4) The REST remember/forget routes keep operator trust: the shared token
  is the authorization, now stated in `routes.swift` and AGENTS.md. Tests: `MemoryFactPolicyTests`
  (5), gate parameterised kick/ban test, server and desktop cap tests. Mutation-checked:
  dropping the kick/ban clause and dropping the eviction each fail their tests. This closes the
  four open bullets above; the goal's remaining scope is the macOS UI half of its sibling.
## Merge the open review branches into main and finish their worktrees
status: done
- Captured 2026-09-16 12:28 EDT from "merge all branches into main and delete the branches not
  needed after". Inventory after `git fetch --prune`: local `cursor/command-surface-truth-20260916`
  (2 commits, never pushed), `cursor/test-defaults-hygiene-20260916` (0 commits, equal to `main`;
  its work existed only as `stash@{0}`, made 12:26:35 by the pre-session branch switch),
  `cursor/test-data-isolation-20260916` (merged as PR #89, upstream gone, clean worktree), and
  `codex/reaction-reward-learning-20260916` (3 pushed commits, no PR, worktree holding 10 staged
  uncommitted files / +421 lines, plus a detached `/private/tmp/.../rr-verify` worktree from
  another session's scratchpad).
- Done: removed the clean, merged `AbbeyBot-wt-test-data-isolation-20260916` worktree and deleted
  its branch (`e71ef43`, an ancestor of `origin/main`).
- The stash was re-applied onto `cursor/test-scratch-defaults-20260916`, stacked on the rebased
  command-surface branch so one `verify-all` run covers the post-merge tree. Its `ScratchDefaults`
  helper replaces UUID-named `UserDefaults` suites, which leave a plist in
  `~/Library/Preferences` on every run (3,008 matching plists there before this run). The empty
  `cursor/test-defaults-hygiene-20260916` ref is superseded by that branch.
- Not merged, deliberately: `codex/reaction-reward-learning-20260916`. It is a Codex-owned,
  default-on DQN reward change whose worktree holds staged work that is not on the branch; merging
  the three pushed commits would ship the feature without its in-progress completion. Needs the
  owner (or Donald) to commit or discard the staged work and open a PR.
- Gate for the stacked tip (command-surface + test-hygiene): `bash Scripts/verify-all.sh`,
  `VERIFY_ALL_EXIT=0` read from the log (desktop 502 tests / 46 suites; server, CLI and web smokes
  green). `~/Library/Preferences` matching plists: 3,008 before and 3,008 after the full run, so
  the converted suites no longer leak. Residual: a fixed-name `TokenBucketRateLimiter.plist` is
  still written there by some test; it does not accumulate and was not changed.
- Superseded 2026-09-16 12:4x EDT by Donald's "complete all": the reaction-reward staged set was
  committed as-is in its worktree, the branch rebased onto `04a7f5c` (#90 + #91), and two of its
  new tests were converted from UUID-named `UserDefaults` suites to `ScratchDefaults` so the branch
  does not reintroduce the leak #91 closed. `verify-all` on that tip: `VERIFY_ALL_EXIT=0` from the
  log (desktop 517 tests / 47 suites). Delayed rewards remain unit-tested only; the live checklist
  in `tasks/todo.md` is still open.
- Outcome 2026-09-16 12:5x EDT: every review branch is on `main` = `origin/main` at `a603ad2`.
  Merged #90 (command-surface, `76fd47e`), #91 (test scratch defaults, `04a7f5c`) and #92
  (delayed rewards, `a603ad2`), each with a merge commit and each gated locally with
  `verify-all` (exit 0 from the log). Removed: the test-data-isolation, reaction-reward and
  `/private/tmp/.../rr-verify` worktrees (all clean), the superseded empty
  `cursor/test-defaults-hygiene-20260916` branch, and `stash@{0}` after diffing its six files
  against `origin/main` (identical). `gh pr merge --delete-branch` removed the reaction-reward
  worktree and local branch itself, after its last commit was pushed. Local state afterwards:
  one worktree, `main` the only local branch, no stashes. Hosted Actions were not relied on.
- Correction 2026-09-16 13:2x EDT: the "fixed-name `TokenBucketRateLimiter.plist`" residual
  above is not AbbeyBot's. `plutil -p` shows an `SKDUserDefaultsRoot` map of Spotlight
  embedding token buckets; nothing in `Sources/` or `Tests/` names it. No test leak remains
  from that measurement.

