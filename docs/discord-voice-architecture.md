# Discord Voice Architecture

Status: **in progress**. AbbeyBot currently has Discord gateway voice presence only. It does not yet send or receive voice audio, and no UI or command may claim otherwise until the release criteria below pass.

## Production boundary

Discord voice is a separate real-time subsystem from the bot gateway:

1. The main gateway sends `VOICE_STATE_UPDATE` and `VOICE_SERVER_UPDATE` after an opcode 4 join request. AbbeyBot must correlate both events for the requested bot, guild, and channel. The events can arrive in either order.
2. A Voice Gateway v8 WebSocket uses those ephemeral credentials to identify, heartbeat, negotiate DAVE, advertise speaking state, resume, and reconnect.
3. A UDP transport performs IP discovery and carries RTP packets protected with Discord's negotiated AEAD transport mode.
4. Opus converts 48 kHz PCM frames to and from Discord audio payloads.
5. DAVE encrypts and decrypts the encoded media frames end to end. Transport encryption alone is not sufficient for current Discord voice channels.
6. A platform audio adapter captures and plays PCM. The macOS desktop adapter will use Apple audio APIs; server and CLI targets must remain buildable without a physical audio device.

The voice server token, session ID, endpoint, transport secret, and DAVE epoch keys are ephemeral secrets. They must remain in actor-owned memory, must not be encoded into SwiftData/Fluent/WDBX/checkpoints, and must not appear in logs, errors, metrics, or UI.

The implemented negotiated-media bootstrap follows that boundary directly. After validating Ready,
Select Protocol, Session Description, and DAVE state, the Voice Gateway constructs a one-shot
capability containing its generation, audio SSRC, typed AEAD mode, 32-byte transport key, and
effective DAVE version. It installs that capability into a session-owned media plane and resolves
only secret-free readiness booleans to the controller. The raw Session Description is not retained.
Reset preserves a generation high-water mark, preventing late tasks from reinstalling retired key
material. This is bootstrap proof, not a packet pump or shipped-audio claim.

## State model

The operator-facing state must distinguish these phases:

- `idle`: no requested voice channel.
- `requestingGatewayState`: opcode 4 was sent; neither event pair nor audio is confirmed.
- `awaitingGatewayPair`: one main-gateway event has arrived.
- `connectingVoiceGateway`: the event pair is complete and the Voice Gateway is connecting.
- `negotiatingTransport`: UDP discovery and AEAD mode selection are in progress.
- `negotiatingDAVE`: MLS/DAVE readiness is in progress.
- `readyMuted`: the encrypted media session is usable but capture is muted.
- `readySpeaking`: capture, Opus, DAVE, RTP, and UDP transmission are active.
- `reconnecting`: a recoverable interruption is being resumed within a bounded retry policy.
- `failed`: a terminal or exhausted failure with a redacted operator-safe reason.

An outbound join request is never equivalent to `readyMuted` or `readySpeaking`. Leaving voice cancels the current generation so late gateway, WebSocket, or UDP events cannot resurrect an old session.

## Component ownership

| Component | Responsibility | Target |
|---|---|---|
| Main-gateway handshake accumulator | Correlate unordered state/server events; reject stale or mismatched events | `AbbeyCore` |
| Voice Gateway v8 client | Identify, heartbeat/ACK, sequence tracking, resume, close-code policy, speaking | `AbbeyCore` |
| UDP/RTP transport | IP discovery, sequence/timestamp/SSRC, AEAD nonce rules, replay window | `AbbeyCore` |
| Opus adapter | 48 kHz encode/decode, frame duration, PLC/FEC controls | C interop module used by `AbbeyCore` |
| DAVE adapter | MLS session, transition IDs, frame encrypt/decrypt, key ratchets | C++/C interop around Discord `libdave` |
| Negotiated media plane | Consume the one-shot key capability; own AEAD, Opus, current-DAVE authority, and retained UDP transport | `AbbeyMediaNative` |
| Audio device adapter | Capture/playback, route changes, permissions, mute/deafen | `AbbeyBotApp` on macOS |
| Headless audio adapter | Explicit no-device/file/test sources and sinks | server/CLI-safe module |
| Voice controller | Own one active generation, cancellation, retry budget, redacted state publication | `AbbeyCore` |
| Commands and UI | Join/leave/mute/deafen/status/device selection with honest phase labels | desktop + slash surfaces |

## Safety and reliability invariants

- Validate `CONNECT` and `SPEAK` permissions before joining; moderation and administration checks remain independent of reinforcement-learning rewards.
- Never allow generated content or DQN strategy choice to auto-join, unmute, change devices, or transmit microphone audio. Those actions require explicit operator intent.
- Default new sessions to capture-muted. Unmute must be explicit and visible.
- Bind every asynchronous callback and packet stream to a monotonically increasing session generation.
- Use bounded queues and backpressure between capture, codec, crypto, and UDP. Audio may be dropped to preserve real-time behavior; memory may not grow without bound.
- Authenticate before decoding untrusted media. Enforce RTP size limits, SSRC mapping, sequence/replay windows, and safe integer arithmetic.
- Redact Discord tokens, voice credentials, transport keys, DAVE key material, and raw microphone data from diagnostics.
- Tear down in the order media-plane reset, Voice WebSocket close, retained UDP socket close; reset must remain idempotent and generation-scoped.
- A reconnect policy must distinguish resumable Voice Gateway failures from a required full main-gateway rejoin, and explicit leave must cancel all retries.
- Audio capture permission denial and missing devices are normal operator-visible states, not crashes.

## Verification required before claiming voice audio is shipped

- Deterministic unit tests cover both main-gateway event orders, mismatches, cancellation, stale generations, duplicate delivery, and secret redaction.
- Protocol fixtures cover Voice Gateway v8 hello/heartbeat/ACK, ready/select-protocol/session-description, DAVE opcodes, resume, close codes, and malformed payloads.
- RTP tests cover sequence and timestamp wraparound, nonce construction, AEAD authentication failure, replay rejection, packet loss/reordering, and known Opus vectors.
- Audio tests cover capture/playback format conversion, mute/deafen, route changes, permission denial, and bounded-buffer behavior without requiring a live device in CI.
- Integration tests use local WebSocket and UDP peers to prove connect, cancellation, timeout, reconnect, and teardown without Discord credentials.
- The repository gate of record passes on every supported package role.
- A live Discord developer guild run proves join, audible send, receive/playback, mute/deafen, reconnect/resume, leave, and DAVE negotiation. The run records redacted evidence only.

Until every item above is satisfied, voice work remains an incomplete production goal and the existing presence-only wording remains the externally accurate product claim.

## Video / Go Live expansion

Video is a separate media track on the same Voice Gateway and DAVE session; completing audio does not complete video. AbbeyBot must keep video disabled until all of the following exist and pass independently:

- Voice Gateway video source and sink signaling, SSRC assignment, codec negotiation, and video-quality/channel-option handling.
- Camera and screen-capture permission flows with an unmistakable live-preview and transmission indicator.
- Hardware-accelerated encode/decode behind a testable codec abstraction, with explicit negotiated profiles, resolution, frame rate, keyframes, and bitrate limits.
- Video RTP packetization/reassembly, loss and reordering behavior, pacing, RTCP/congestion feedback where required, and bounded frame queues.
- DAVE frame encryption/decryption for every supported video codec and media transition; transport-only video is not a completion state.
- SwiftUI preview, participant layout, camera/screen selector, pause/resume, failure state, and immediate stop controls.
- Deterministic encoded-frame fixtures, local lossy-network tests, resource/thermal measurements, and a live DAVE-enabled Discord camera plus Go Live validation.

No camera or screen capture may start from a model-generated action, reconnect automatically after an explicit stop, or retain frames by default. Voice and video each require explicit operator enablement and expose independent kill switches.
