# Todo

Granular steps under `tasks/goals.md`. Coarse intentions live there, not here.

## September 8 integration closeout

See the [current evidence and completion audit](../docs/verification/product-integration-2026-09-08.md)
for commit-specific results. Dated entries below retain their original scope.

- [x] Strictly fast-forward the original baseline and merge the WebKit delegate
      and native compiler/DAVE test corrections through PRs #83 and #84.
- [x] Pass the complete ordinary gate at `f287cdd`, including the active-preview
      replacement fixture correction in PR #85; pass 30 deployment tests.
- [x] Complete PR #85 follow-on integration and synchronize canonical `main`:
      `main`, `origin/main`, and remote `main` were observed equal at
      `a9b6c1712178b664d217eab03b55e0c2475f66d3`; CI run 34217866364 and release
      run 34217866428 succeeded on that SHA.
- [x] Record the selected CI-published release image identities and native
      qualification scope: app digest `sha256:6a7d9ea4b8a0b428c063ef87664d121ac4926f5bca4602a4048fbb1554722440`,
      Caddy digest `sha256:31698e48b2971c0e3332508f05bf3c59f28530077305b6cc81d012c8430ca8b1`;
      native debug/release each passed 102 tests in 9 suites. Registry inspection,
      deployment, live media qualification, and wire codec selection remain open.
- [ ] Complete SSH/domain/registry/R2 prerequisites and production recovery drills.
- [ ] Prove deployed real-model Quasar, Discord proposal denial and Twitch delivery.
- [ ] Observe consented Discord codec negotiation, complete the observed media
      composition, and collect the required content-free qualification receipt.

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

- [x] Harden the DiscordBM main-gateway lifecycle: READY remains the connected authority, explicit
      disconnect closes the pinned manager, failures become observable, and voice presence is not
      reported as joined before Discord confirms the bot's own `VOICE_STATE_UPDATE`.
      *(Closed 2026-08-03: the injected `DiscordGatewayDriver` seam exercises the real
      `DiscordBridge` event loop. Ten bridge lifecycle tests cover READY authority, retained
      disconnect, normal/failed stream termination, both voice-event orders, wrong identities,
      timeout and leave acknowledgement, stale epochs, and the real controller+bridge deadline
      collision. The collision emits one null-channel cleanup, holds replacement behind the
      authoritative leave barrier, and rejects late callbacks.)*
- [x] Pair the unordered self `VOICE_STATE_UPDATE` and `VOICE_SERVER_UPDATE` events in a
      generation-scoped handshake accumulator; cover both event orders, wrong guild/user/channel,
      nil endpoint, stale partials, cancellation, timeout, and single-emission behavior.
      *(Audited 2026-08-03: `VoiceGatewayHandshake.swift` + `VoiceGatewayHandshakeTests` cover
      every listed sub-requirement, and `DiscordBridgeLifecycleTests` now exercises the real
      bridge-side consumption and cleanup ownership.)*
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
      *(PARTIAL 2026-08-20 — in-session buffered resume landed in
      `DiscordVoiceGatewaySession`: the transport now runs in a bounded loop; only a `.resume`
      close disposition (which requires an established, `resumeEligible` session) retains
      credentials, transport keys, and the installed media plane, re-opens the same endpoint
      through injected backoff, sends op-7 Resume (never Identify) on Hello, and re-establishes
      on op-9 Resumed — the attempt budget (`maximumResumeAttempts`, default 3, 0 disables)
      refills only on a successful Resumed. Every other outcome — pre-established drops,
      reidentify/terminal codes, protocol violations, budget exhaustion — takes the exact
      credential-dropping teardown that existed before, and explicit `disconnect()` wins over an
      in-flight backoff. New session phase `.resuming` is honest in snapshots
      (`signalingEstablished == false` during the gap). Five new hermetic tests drive multi-attempt
      scripted transports (`DiscordVoiceGatewayResumeHarness`); full `AbbeyCoreTests` 312 green.
      Still open in this bullet: controller-level full-reconnect fallback is NOT auto-triggered —
      `DiscordVoiceController.reconnect()` exists and is tested but nothing invokes it on session
      failure; invalid-session, channel-move, and process-shutdown
      verification remain unattempted; live-network resume evidence stays operator-blocked.)*
      *(PARTIAL 2026-08-20 — induced UDP loss/reorder verified at the UDP layer only, via
      hermetic 127.0.0.1 loopback fault injection — this is LOCAL loopback evidence, not
      live-network evidence. Six new tests in `DiscordVoiceUDPSessionTests` /
      `DiscordVoiceUDPDiscoveryTests`: (1) dropped discovery response → bounded timeout, no
      in-call retransmit, session returns to `.open`, and a caller-driven retry completes on the
      SAME socket/source port (NAT-mapping invariant), plus the one-shot client equivalent;
      (2) truncated (73-byte) and SSRC-mismatched discovery responses fail closed
      (`invalidPacketSize` / `ssrcMismatch`) while preserving the socket for a later intact
      response, in both session and client; (3) duplicated + reordered media datagrams are
      delivered exactly as received — the session deliberately does no dedupe/reorder/replay
      handling (RTP sequence numbers and SRTP replay protection above it own that), and a late
      duplicate discovery response after readiness is opaque media-path bytes that do not disturb
      state. No production code changes were needed — existing behavior held under all injected
      faults. NOT covered here: loss/reorder during active encrypted RTP flow end-to-end through
      the controller/media plane (owned by PR #61's layer), gateway-driven re-discovery after
      loss, and any live-network UDP evidence. Gate: full `AbbeyCoreTests` 320 green +
      `check-static-security.sh` STATIC_SECURITY_GREEN.)*
      *(PARTIAL 2026-08-20 second slice — the controller-level full-reconnect fallback is now
      wired. `DiscordVoiceGatewaySessionClient` gained `awaitTermination() -> Bool` (default
      `false` keeps the fallback inert for fakes/unaware clients); the production session resolves
      it `true` only on the credential-dropping terminal teardown and `false` on operator
      disconnect. After every ready join the controller starts a generation-scoped monitor —
      strictly AFTER the ready transition, with no suspension point between, so a pending verdict
      can never be stomped by the join's own tail (an actor-reentrancy race the budget-exhaustion
      test caught live). Unexpected termination triggers the existing `reconnect()` full rejoin
      through a bounded budget (`maximumAutoReconnectAttempts`, default 2, refilled only by a
      fresh operator join) with deterministic 1/2/4/8s-capped delays via the injected sleeper;
      exhaustion fails closed as `.gatewayUnavailable`. Kick/move policy: before any rejoin the
      fallback consults `voicePresenceHeld()` on the pair bridge (production adapter reads
      `DiscordBridge.voicePresenceState().confirmedInChannel`); presence lost = Discord-initiated
      removal = fail closed, never rejoin — 4014 close-code discrimination is deliberately NOT
      attempted at the session layer. (Review pass corrected the original claim that the bridge
      clears the controller target on removal; no such wiring exists, and the review also fixed a
      live-disconnect leak where `terminationSignal` was never resolved because `disconnect()`
      bumps the generation before the cancelled transport loop reports back.) Five controller tests (rejoin, operator-cause inertness, bounded
      exhaustion, budget refill, stale-monitor immunity), suite 22/22 stable across 10 runs after
      fixing a test-harness race (one injected sleeper drives both the credential-timeout race and
      the backoff — park timeout-sized sleeps, instant backoff sleeps). AbbeyCoreTests 317 green.
      Still open: induced UDP loss/reorder, invalid-session, channel-move, process-shutdown
      verification; live-network evidence remains operator-blocked.)*
- [ ] Expand `/voice` and the Discord SwiftUI surface with honest connection phases, guild/channel
      selection, join/leave/status, mute/deafen, PTT/VAD, device/volume controls, speaking meters,
      reconnect/error visibility, stage-channel state, permission preflight, privacy policy, and an
      immediate capture kill switch.
      *(2026-08-04: Closed the gateway-presence slice of this item — mute/deafen and honest
      connection-phase visibility, nothing else. `DiscordBridge.updateVoiceMuteState(selfMute:
      selfDeaf:)` sends a real `VOICE_STATE_UPDATE` for the already-confirmed channel; the tracked
      `voiceSelfMute`/`voiceSelfDeaf` only ever update from Discord's own echo in
      `handleVoiceStateUpdate`, never optimistically. `MediaSessionModel` gained a
      `VoicePresencePort` (hermetically fakeable) wiring this into `DiscordView`'s new self-mute/
      self-deaf toggles, gated on confirmed presence. Added a literal `connectionPhaseLabel` —
      one phrase per `DiscordVoiceControllerPhase` case (idle → requesting → awaiting pair →
      connecting → negotiating transport → negotiating DAVE → ready → reconnecting → failed) —
      alongside the existing signaling/transport copy, so the view never implies more than a
      connected/disconnected binary. This is presence-only signaling: there is still no Opus/UDP
      audio to silence, and it is distinct from `AVAudioEngineAdapter.setMuted` (still unwired to
      Discord, see the AVAudioEngine PARTIAL bullet below). Caveat found and disclosed in-view:
      both `DiscordVoiceSessionFactory` implementations still report `mediaAdapterAvailability ==
      .unavailable`, so `DiscordView`'s own "Probe transport" button always ends by leaving
      (`fail(.mediaUnavailable)` drains the leave before `join()` returns) — the new toggles are
      reachable only while presence is held via Discord's `/voice join` slash command (which does
      not auto-leave), not via this view's own join affordance. Also fixed a torn-read risk:
      `DiscordBridge.voicePresenceState()` returns confirmed-channel + self-mute + self-deaf from
      one actor-isolated read instead of three separate hops. PTT/VAD, device/volume controls beyond
      the existing pickers, speaking meters, reconnect/error visibility, stage-channel state, and
      privacy-policy copy remain open and were not attempted here — see
      `Tests/AbbeyBotAppTests/MediaSessionModelTests.swift` and
      `Tests/AbbeyCoreTests/DiscordBridgeLifecycleTests.swift` for the new coverage.)*
- [ ] Add the voice gate: protocol/unit fixtures, scripted local Voice WebSocket (done
      2026-08-04 — see `Tests/AbbeyCoreTests/VoiceGatewayLoopbackWebSocketTests.swift`), real UDP
      loopback, codec/crypto/DAVE tests, audio-device tests, and fault injection; then run the full
      repository gate. Do not mark live capability complete from local tests alone.
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

### Phase 4 negotiated-media bootstrap slice (2026-08-03)

- [x] Added a one-shot, in-memory `DiscordVoiceNegotiatedMediaCapability` carrying the Voice
      Gateway generation, Ready audio SSRC, selected typed AEAD mode, exact 32-byte Session
      Description key, and effective DAVE version directly from `DiscordVoiceGatewaySession` to
      its session-owned media plane. The key has no getter, Codable/Equatable conformance, UI or
      controller route, snapshot field, log representation, or synthesized reflection surface.
- [x] Removed the retained raw Session Description from the Gateway actor. Session Description now
      installs the capability before resolving a secret-free readiness signal; repeated
      negotiation does not reinstall the key. DAVE epoch changes re-attest the media plane's
      current native session without caching a replaceable `NativeDAVESession`.
- [x] Added `DiscordVoiceNativeMediaPlane`: it constructs one RTPSIZE encryption owner and one
      Opus owner against the exact retained UDP discovery/media socket, rejects duplicate/stale
      generations across reset, prevents suspended initialization from publishing after reset,
      and exposes only redacted boolean state. The native factory still reports `.unavailable`
      and advertises DAVE 0, so this bootstrap is not misreported as shipped audio.
- [x] Enforced and tested teardown ordering: media-plane reset precedes local Voice WebSocket
      close, and Gateway disconnect completes before the retained UDP socket closes. Focused Core
      verification passed 67 tests in 4 suites; fresh pinned native debug and release each passed
      52 tests in 7 suites, output secrecy passed, `STATIC_SECURITY_GREEN` and
      `NATIVE_MEDIA_SMOKE_GREEN` were emitted.
- [x] Phase 5 closed 2026-08-04: `DiscordVoiceNativeMediaPlane.sendAudioFrame(pcm:)` composes the
      full send path — encode via `Opus20msCodec`, DAVE-protect via the installed
      `NativeDAVESession.protect(...)` (fails closed with `.daveProtectionRequired` unless the
      generation attested a ready DAVE session), build the RTP header via the existing
      `DiscordVoiceRTPCodec`/`DiscordVoiceRTPClock` (clock tick and the one-shot Speaking gate are
      reserved synchronously before the first `await` so two overlapping sends can't race the same
      sequence number or double-fire Speaking), seal via the installed
      `DiscordVoiceTransportEncryption`, and send through the retained
      `DiscordVoiceMediaDatagramTransport`. `DiscordVoiceGatewaySession.connect()` now attaches a
      real Speaking callback to the media plane that calls the previously-modeled-but-never-sent
      `machine.speaking(flags: 1)` and sends it over the live WebSocket session — closing the
      Phase 1 audit's "speaking(flags:) is modeled and tested but not yet sent by the production
      session" caveat. `sendAudioFrameComposesTheFullSendPath` proves all six required properties
      over 3 sent frames: DAVE protection is real (wire payload matches DAVE's actual output, not
      the raw Opus bytes a bypass would send), RTP sequence/timestamp advance deterministically,
      AEAD counters are unique and verified by actually decrypting each wire packet, Speaking fires
      exactly once before the first packet, and five dedicated fail-closed tests prove no send ever
      reaches the transport without an installed generation, without attested DAVE, when DAVE
      protection fails, when the Speaking signal fails, or when `reset()` interrupts a suspended
      send. **Still open, not attempted here:** nothing in production calls `sendAudioFrame` yet —
      there is no capture loop (that's the `AVAudioEngine` composition item below) — so the native
      factory correctly still reports `.unavailable` and advertises DAVE 0; this closes the send-path
      composition boundary only, not shipped audio. Verified: native gate 59/59 tests in 7 suites
      (debug + release), output secrecy and `STATIC_SECURITY_GREEN`, `NATIVE_MEDIA_SMOKE_GREEN`; the
      four non-desktop targets 472/472 (`AbbeyCoreTests` 303 + `AbbeyServerKitTests` 117 +
      `AbbeyCLITests` 30 + `AbbeyServerTests` 22), `EXIT:0`.
- [x] Phase 6a (capture composition, 2026-08-20): production now has a capture loop that calls
      `sendAudioFrame`. New portable `DiscordVoiceCaptureLoop` actor
      (`Sources/AbbeyCore/Discord/DiscordVoiceCaptureLoop.swift`) pumps exact 20 ms 48 kHz stereo
      Int16 frames from an injected `DiscordVoiceCaptureSource` into a
      `DiscordVoiceAudioFrameSender` — `DiscordVoiceNativeMediaPlane` conforms, so the loop drives
      the full Phase 5 protected path (Opus → DAVE protect → RTP → AEAD → retained socket) and can
      never bypass it. Composition: `DiscordVoiceNativeControlSessionFactory` accepts an optional
      capture source and binds a loop to the session-owned media plane in its components;
      `DiscordVoiceController` owns the gating — enabling the microphone starts capture for the
      current established generation, muting stops capture at the device boundary, a start failure
      or loop terminal fails closed to mic-disabled with the new operator-visible
      `.captureUnavailable` failure, and teardown stops capture *before* the gateway disconnect
      resets the media plane. Desktop wiring: `MicrophoneCaptureSource` (AbbeyBotApp) bridges the
      shared `AVAudioEngineAdapter` (same instance as the platform's device selection/kill switch)
      to the loop; permission preflight stays inside the adapter, and any engine interruption or
      device/configuration change finishes the stream so the loop fails closed — no automatic
      restart. Loop fail-closed rules covered by tests: stale/zero generation rejection (equal
      generation restarts across a mute cycle), double-start rejection, malformed frame, sender
      failure, unexpected capture end, start failure with retry, ordered stop with nothing sent
      after it. Verified this tree: non-desktop 493/493 (`AbbeyCoreTests` 324 incl. 13 new +
      `AbbeyServerKitTests` 117 + `AbbeyCLITests` 30 + `AbbeyServerTests` 22) `EXIT:0`; desktop
      604/604 across 6 bundles (incl. 4 new `MicrophoneCaptureSourceTests`) `EXIT:0`; native bundle
      61/61 in 8 suites `EXIT:0` (2 new composition tests prove fake-source → loop → real plane →
      2 ordered protected wire packets with Speaking exactly once, and a pre-negotiation loop sends
      nothing); `STATIC_SECURITY_GREEN`.
- [ ] Phase 6 remains open for the honest availability flip: the native factory still reports
      `.unavailable` and advertises DAVE 0 **deliberately** — receive/decode/playback, jitter
      handling, reconnect behavior for the capture path, PTT/VAD and UI capture controls, and live
      DAVE-enabled call evidence are still missing, so send-side capture composition alone must not
      be presented as shipped audio. (Because availability is unchanged, the controller never
      reaches `readyMuted` in production yet; the capture path is exercised by deterministic tests
      only.)

### Voice audit snapshot (2026-08-01, read-only, two parallel agents)

Open items above, graded against the committed tree at `2a423e1`:
- **Historical item 1 result (superseded 2026-08-03): gateway lifecycle was PARTIAL** — implementation hardened (generation-scoped READY
  authority, presence only from confirmed self `VOICE_STATE_UPDATE`, real `disconnect()`), but
  `DiscordBridge.handleVoiceStateUpdate`/`handleVoiceServerUpdate` then had zero bridge-level tests.
  The Phase 1/2 closure above now supplies ten real bridge lifecycle tests, including the
  controller/bridge timeout collision.
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
  meters, gateway self-mute/self-deaf presence toggle, and a literal per-phase connection-state
  readout (2026-08-04, gateway-presence-only, not wired to `AVAudioEngineAdapter.setMuted`);
  missing PTT/VAD, volume/speaker-level controls, and stage-channel state.
- **Voice gate PARTIAL, narrowed 2026-08-04** — real UDP loopback yes; scripted local Voice
  WebSocket server now also yes: `Tests/AbbeyCoreTests/VoiceGatewayLoopbackWebSocketTests.swift`
  binds a real `NIOTypedWebSocketServerUpgrader`-based server to `127.0.0.1:0` and drives it with
  the production `WSClient.WebSocketClient` (via a test-only `VoiceGatewayClientTransport.loopback`
  runner that reuses `.live()`'s exact internal session-bridging code, `@testable`-visible), proving
  a genuine HTTP/1.1 Upgrade handshake and real WebSocket frame (de)serialization end-to-end through
  `VoiceGatewayClient` + `VoiceGatewayV8StateMachine`: Identify→Ready→Select Protocol→Session
  Description reaching `established`/`terminated`, a real 4014 close frame producing
  `.terminalClose(4014)`, and a withheld heartbeat ACK producing a real 1001 close from the client
  and `.reconnectLimitReached`. `VoiceGatewayClientTests.swift`'s in-process fake-transport suite is
  unchanged and still covers reconnect/backoff/cancellation edge cases the real-socket tests don't
  re-derive. Still open: codec/crypto/DAVE payload correctness over this real transport, audio-device
  tests, and fault injection (packet loss/reorder, mid-handshake disconnects) are explicitly out of
  this slice's scope; `ABBEY_NATIVE_MEDIA=1` suites remain outside CI.
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

### Video send-boundary composition slice (2026-08-20, extends audio Phase 5 to `.video`)

- [x] `DiscordVoiceNativeMediaPlane.sendVideoFrame(encodedFrame:)` composes the outbound video
      send path with the exact audio Phase 5 pattern: DAVE-protect the already-encoded frame via
      the installed `NativeDAVESession.protect(_:mediaType:.video, codec:, ssrc:)` (fails closed
      with `.daveProtectionRequired` unless the generation attested a ready DAVE session — no
      transport-only or plaintext video path exists), build the RTP header via the extended
      `DiscordVoiceRTPCodec` with the negotiated video payload type and marker bit set on the
      frame boundary, tick a new 90 kHz `DiscordVoiceVideoRTPClock` (tick and the one-shot
      announcement obligation are reserved synchronously before the first `await`, mirroring the
      audio sequence/Speaking reservation), seal via the same installed single-owner
      `DiscordVoiceTransportEncryption` (audio and video counters share one never-reused nonce
      sequence), and send through the retained `DiscordVoiceMediaDatagramTransport`.
- [x] `installVideoSource(allocation:activeRIDs:codec:ticksPerFrame:)` binds the video SSRC from
      the existing bounded `VoiceGatewayV8VideoSSRCAllocation` Ready models — clients never invent
      video SSRCs — and rejects foreign allocations (audio SSRC mismatch) and codecs with no
      modeled Discord payload type (Opus, H.265). Payload types follow the community-documented
      client proposals: H264 101, VP8 103, VP9 105, AV1 107; RTX payload types are deliberately
      not accepted anywhere (no RTX path exists).
- [x] Announcement-before-send: `DiscordVoiceGatewaySession.connect()` attaches a video
      announcement callback alongside Speaking; the media plane fires it exactly once per
      installed video source before the first protected packet, and the new
      `VoiceGatewayV8StateMachine.videoAnnouncement(_:)` validates the Opcode 12 payload against
      the Ready allocation (client-owned, matching audio SSRC, only server-assigned stream SSRCs)
      before it reaches the socket. Unlike Speaking, a missing announcement callback fails the
      send closed — Discord documents the announcement as mandatory before video media.
- [x] Proof mirrors Phase 5: `sendVideoFrameComposesTheFullSendPath` decrypts every wire packet
      and asserts real DAVE output (never the raw encoded frame), 90 kHz timestamps/sequence,
      payload type 103/marker/SSRC, shared AEAD counter continuity after an audio frame,
      announcement-exactly-once, and teardown via `reset()`; eight dedicated fail-closed tests
      cover no-install, no-video-source, DAVE-never-attested (install and send), foreign
      allocation/non-video codec, empty frame, announcement missing/failing, protect failure, the
      real pinned-libdave unready session, and reset-mid-send. A session-level test proves the
      gateway sends Opcode 12 for a Ready-backed announcement and fails closed on foreign SSRCs
      and after disconnect.
- [ ] **Still open, not attempted here (do not upgrade the claim):** nothing in production calls
      `sendVideoFrame` — no camera/screen capture wiring, no video encoder, no codec negotiation
      completion (payload types are modeled client proposals, not a negotiated selection), no MTU
      packetization/pacing (one whole encoded frame per packet, marker always set), no
      keyframes/RTX/feedback, no receive/reassembly/render path, no congestion/loss/perf
      coverage, and no live camera or Go Live evidence. No capability advertisement changed; the
      native factory still reports `.unavailable`.

### Video audit snapshot (2026-08-01, read-only)

Nothing checkable; graded against `2a423e1`:
- **Signaling MISSING** — no video opcodes exist; inbound opcode 12 is an explicit
  `unsupportedOpcode` error; no video SSRC allocation, no source announce/sink wants.
- **Capture PARTIAL (the real work so far)** — `VideoCaptureAdapter` is genuine
  AVFoundation/ScreenCaptureKit with permission gating, source enumeration/selection, screen-lock
  kill, bounded queues, and 17 hermetic tests. But there is no preview surface, and nothing in the
  app can call `startCapture()` — `MediaSessionPlatform` exposes only `stopAllCapture()`.
- **Video RTP/codec MISSING (partially superseded 2026-08-20)** — `DiscordVoiceRTPMediaKind.video`
  was a label only. The send-boundary slice above added video payload types, a 90 kHz clock, and
  marker semantics to the RTP layer; still no pacer, keyframes, RTX/feedback, reassembly, or
  negotiation fields on Select Protocol.
- **DAVE video PARTIAL (superseded 2026-08-20)** — `NativeDAVESession` accepted `.video` + five
  codecs with zero video callers and zero video tests. The send-boundary slice above is now a
  real `.video` caller with composition and fail-closed tests, including the real pinned binding's
  own fail-closed `protect`; genuine multi-party MLS video ciphertext still cannot be produced in
  this environment (see the audio Phase 5 note on roster activation).
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

## PR #64 automated-review findings (2026-08-20) — dispatched, not yet verified

Seven findings on the merged PR #64 diff. Each is being fixed by a
worktree-isolated agent; none is closed until its gate is green here and the
thread is answered on GitHub. Comment ids kept so replies can be posted.

- [x] **P1 `TwitchBridge.swift`** (3822336981) — FIXED `83b5e96` — byte transport split behind `TwitchIRCByteStream`; CFStream keeps TLS unconditionally (no cleartext mode at all), a non-gated POSIX loopback socket restores the Linux test path, and three barriers keep the token off the wire including a hardcoded loopback literal with no resolver. AbbeyCoreTests 342/342. ORIGINAL: — the `#if canImport(Darwin)`
      guard added for the CFNetwork TLS break wraps the WHOLE `connect`, so it
      also throws for `useTLS == false`. Both real-socket tests call
      `connectInsecureLoopbackForTesting` and would fail on Linux, and Linux CI
      runs the full `AbbeyCoreTests` bundle. **This one is self-inflicted** —
      guard only the TLS setup, keep plaintext loopback working, keep
      production TLS fail-closed (plaintext to a real host would put the
      OAuth token on the wire).
- [x] **P1 `DiscordVoiceController.swift`** (3822336984) — FIXED `5b2e5c0` — `pendingMicrophoneDesiredState` + reconcile loop; mute path clears the flag before `stop()` suspends. Red baseline proved first. ORIGINAL: — an operator mute that
      lands while `captureLoop.start` is suspended is dropped; the resuming
      start then enables the microphone after the mute appeared to succeed. A
      privacy action must never be lost to actor reentrancy.
- [x] **P2 `DiscordVoiceController.swift`** (3822336997) — FIXED `5b2e5c0` — terminal-during-start is recorded and the resuming start fails closed on it. ORIGINAL: — a capture loop that
      fails immediately can fire its terminal handler before the controller has
      set `microphoneEnabled`; the guard drops the event and the microphone is
      then published as enabled while the loop is already failed.
- [x] **P2 `DiscordVoiceController.swift`** (3822337010) — FIXED `5b2e5c0` — a provably-successful start clears a stale `.captureUnavailable`. ORIGINAL: — a successful retry
      after `captureLoop.start` throws does not clear `.captureUnavailable`, so
      the snapshot reports an enabled microphone AND a capture failure for the
      rest of the generation.
- [x] **P2 `DiscordVoiceNativeMediaPlane.swift`** (3822337023) — FIXED `63a6f6e` — video-only `videoRevision` counter re-checked at all four suspension points, so a superseded source cannot transmit under the obsolete SSRC. Chosen over bumping `revision` (would kill legitimate in-flight audio sends). Red-proved by removing the guards: a packet under the old SSRC did reach the transport. ORIGINAL: — `installVideoSource`
      replaces the source without advancing `revision` or cancelling in-flight
      sends, so a `sendVideoFrame` suspended on announcement/DAVE work can still
      transmit with the obsolete SSRC and codec after a source switch.
- [x] **P2 `VoiceGatewayV8StateMachine.swift`** (3822337037) — FIXED `63a6f6e` — Ready indexed as primary→derived-RTX; both halves must match, and the top-level `video_ssrc`/`rtx_ssrc` too. Red-proved: removing the guard fails exactly the three foreign-RTX assertions. ORIGINAL: — Opcode 12
      validation checks only each stream's primary SSRC, so an arbitrary
      explicit `rtx_ssrc` can be announced despite the method's stated
      allocation guarantee. Validate primary AND RTX against Ready.
- [x] **P2 `MediaSessionModel.swift`** (3822337045) — FIXED and verified on main.
      Root cause was ownership: one `AVAudioEngineAdapter` was handed to both
      `MicrophoneCaptureSource` and `MacOSMediaSessionPlatform`, and
      `stopNow()` emits no runtime event, so the bridge's fail-closed path
      never fired. `stopAllCapture()` now runs
      `video.killSwitch()` → `audio.stopNow()` → `microphone?.stopCapture()`,
      which finishes the delivered stream; the capture loop then fails closed
      and the controller drops the microphone. Because `stopAllCapture()` is
      the single chokepoint, all five paths (`stopLocalCapture`, `leave`,
      `disconnect`, `stopAllMedia`, `shutdown`) are covered. Re-enabling after
      a kill works and is asserted end to end. Three new tests, each
      mutation-checked: commenting out the added call makes all three fail.
      AbbeyBotAppTests 77/77, AbbeyCoreTests 340/340, build exit 0.
      *Residual (read-verified, not test-verified):* deliberate leave paths stop
      capture before controller teardown, so a transient `.captureUnavailable`
      is published; it is not operator-visible because no view reads `failure`
      outside a `.failed` phase and the later snapshot carries a bumped
      generation.
- [x] ~~**P2 `MediaSessionModel.swift`** (3822337045) — the UI kill switch calls
      `audio.stopNow()` directly, bypassing `MicrophoneCaptureSource.stopCapture()`.
      The adapter's stream stays open, the capture loop never sees a terminal
      event, and the controller keeps reporting the microphone enabled after the
      device has stopped.~~

Note: the three controller findings are one underlying shape — actor reentrancy
across the `await` in capture startup — and are being fixed as one mechanism
rather than three patches.

## Delayed rewards — live evidence (open, 2026-09-16)

Design: `docs/superpowers/specs/2026-09-16-abbey-delayed-rewards-design.md`. Slices 1-4 are
unit-tested and `verify-all` green on `codex/reaction-reward-learning-20260916`; none of this
is live-proven. Needs a bot token and a private test guild from Donald.

- [ ] Send a message; Abbey replies.
- [ ] React 👍 as the author; `/status` "Replay buffer" rises by exactly 1.
- [ ] On a second reply, delete it; the buffer rises by 1 and the journal shows reward −1.5.
- [ ] Purge (bulk delete) a third reply; the buffer rises by 1.
- [ ] From the desktop app, kick a throwaway account Abbey answered: on confirm the journal
      shows −1; on cancel it shows nothing.
- [ ] Set `ABBEY_DELAYED_REWARDS=0`, restart; `/status` shows "Delayed rewards: off" and a 👍
      adds nothing.
- [ ] Upstream: DiscordBM 1.16.2 (`b01d40b`, Gateway.swift:1385) decodes
      `MessageReactionAdd.member` as required, so DM reactions never arrive. No issue exists
      yet; filing it is Donald's call.

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
