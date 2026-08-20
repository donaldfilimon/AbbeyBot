# Voice receive/playback + video negotiation and packetization — design

**Date:** 2026-08-20 · **Status:** approved, dispatched
**Decisions taken by Donald:** per-SSRC demux **with** mixing; jitter buffer **with** PLC;
video scope limited to **negotiation + packetization** (no rendering, no camera pipeline).

## Why this is smaller than it looks

Every receive-side *primitive* already exists and is tested. This work is composition, in the
same shape as the Phase 5 send-path composition and the Phase 6a capture composition:

| Step | Already exists |
|---|---|
| UDP receive | `DiscordVoiceUDPSession.receiveProtectedPacket()` |
| RTP header parse | `DiscordVoiceRTPCodec.decodeHeader(from:)` |
| AEAD decrypt | `DiscordVoiceTransportEncryption.open(_:)` |
| DAVE decrypt | `NativeDAVESession.unprotect(...)` |
| Opus decode | `Opus20msCodec.decode(_:useFEC:)` |
| Loss concealment | `Opus20msCodec.decodePacketLoss()` — **currently unused** |
| Playback | `AVAudioEngineAdapter.play(_:)` + `playbackQueueDepth()` |

What is missing is the composition, per-SSRC demux, an ordering policy, and mixing.

## §1 Decryption boundary (load-bearing)

Receive mirrors send: **the native media plane owns the keys; the portable layer never sees
them.** `DiscordVoiceNativeMediaPlane` gains a receive entry point that performs AEAD `open` →
DAVE `unprotect` → Opus `decode` and returns the decoded PCM plus its source SSRC. It must:

- Reserve `revision` (and any video counterpart) synchronously before the first `await`, and
  re-check after every suspension point — the established fail-closed idiom.
- Fail closed on every failure: an unauthenticated, undecryptable, or malformed packet is
  dropped and counted. There is no path that yields unauthenticated audio to a caller, and no
  error may carry key material, SSRCs, or packet contents.
- Refuse to run at all unless a generation is installed with an attested DAVE session, exactly
  as `sendAudioFrame` does.

## §2 Portable receive loop

`DiscordVoiceReceiveLoop` in AbbeyCore, modeled on `DiscordVoiceCaptureLoop`:

- Pumps `receiveProtectedPacket()`, parses the RTP header, routes by SSRC.
- Generation-guarded: a superseded revision stops silently; a malformed frame or a terminal
  transport error ends the loop through a terminal handler the controller registers.
- **Ordered teardown**: the loop's `stop()` drains its pump before returning, so the owner may
  reset the media plane immediately afterwards without a packet racing the reset.
- Redacted diagnostics only — counts and phases. No PCM, no packet bytes, no device detail.

## §3 Jitter buffer, PLC, and mixing

Per SSRC:
- Bounded reorder buffer keyed on RTP sequence number, target depth ~4 packets (≈80 ms).
  Bounded so a hostile or broken sender cannot grow memory without limit.
- Duplicate and replay rejection by sequence number.
- A gap that cannot be filled within the buffer's depth is concealed with `decodePacketLoss()`.
- Idle SSRCs evict after a timeout so a busy guild does not leak decoders.

Mixing: decoded 20 ms frames from all active SSRCs are summed into one frame for playback, with
an explicit clipping guard (saturating, not wrapping — a wrap would turn overlap into a loud
artifact).

**Determinism is a requirement, not a nicety:** the buffer and eviction take an injectable clock.
No test may depend on wall-clock sleeps; the ordering and PLC tests must be reproducible.

## §4 Video negotiation + packetization

- **Negotiation**: select the codec and payload type from what Ready / Session Description
  actually negotiated, rather than the client-proposed payload types currently modeled.
  Fail closed when the negotiated codec has no supported mapping.
- **Packetization**: replace one-frame-per-packet with MTU-aware fragmentation. The RTP marker
  bit must be set **only on the last fragment of a frame** — today it is always `true`, which is
  wire-incorrect for any frame above MTU.
- Out of scope here: rendering, receive/reassembly of video, RTX, keyframe policy, congestion
  control, and the camera pipeline.

## §5 Claim honesty

This closes composition boundaries only. Nothing here has run against Discord.
`mediaAdapterAvailability` stays `.unavailable`, the advertised DAVE version stays `0`, and no
document may describe receive or video as working. Live join/speak/hear evidence remains
operator-blocked (no bot token or dev guild in this environment).

## §6 Testing

- **Loopback round-trip**: PCM → send path → receive path → PCM, asserting the decoded output
  corresponds to the input, and that a packet which bypassed DAVE is distinguishable on the wire.
- **Fault injection**: reuse the existing hermetic UDP loss/reorder/corruption harness for
  out-of-order, duplicated, and truncated packets; assert reordering, replay rejection, and PLC.
- **Fail-closed**: a packet failing AEAD or DAVE yields no audio and is counted.
- Red-baseline discipline: every regression test must be observed failing on the pre-fix code
  before it is accepted as pinning anything.
- The authority for media-plane changes is `bash Scripts/run-native-media-smoke.sh`
  (`NATIVE_MEDIA_SMOKE_GREEN`, debug and release). AbbeyMediaNative tests do not run under the
  normal test filter.

## §7 Parallel dispatch — disjoint file ownership

| Agent | Owns | Must not touch |
|---|---|---|
| 1 | `DiscordVoiceNativeMediaPlane.swift` (receive side) + its tests | controller, RTP, gateway models |
| 2 | new receive-loop/jitter/mixer files, `DiscordVoiceController.swift` + tests | media plane, RTP, gateway models |
| 3 | `DiscordVoiceRTP.swift`, `VoiceGatewayV8*.swift` + tests | media plane, controller |

Agent 3 builds the packetizer but does **not** wire it into the media plane; that wiring is a
small follow-up after merge. This split is deliberate: on 2026-08-20 two agents both editing the
media plane produced a merge conflict *and* silently reintroduced two bugs that had just been
fixed, because the second agent modeled its code on the pre-fix shape.


---

## §4 correction (2026-08-20): the negotiation premise was wrong

§4 said codec selection should come "from what Ready / Session Description actually negotiated."
**They carry nothing about codecs.** Verified by reading the models, not assumed:
`VoiceGatewayV8Ready` has `ssrc`/`ip`/`port`/`modes`/`streams`; `VoiceGatewayV8Stream` has
`type`/`rid`/`quality`/`active`/bitrate/framerate/resolution/`ssrc`/`rtx_ssrc`;
`VoiceGatewayV8SessionDescription` has `mode`/`secret_key`/`dave_protocol_version`. A repo-wide
grep for `video_codec|audio_codec|payload_type` returns zero hits.

The right response was **not** to add a `video_codec` CodingKey — that would check an unverified
protocol claim into the repo, which AGENTS.md forbids. Instead the resolver
(`DiscordVoiceVideoCodecNegotiation`) is the single route from a codec name to a payload type and
fails closed on `nil`, blank, unmapped, and out-of-offer-table inputs. Since no payload supplies a
name today, the only reachable input is `nil` → throws. **That is the correct state: no video
codec is negotiated, so no video may be sent.**

Discovering where the negotiated codec name actually arrives requires verification against live
Discord, and is now a separate open question rather than an assumption baked into code.

The packetizer is unaffected by this and landed as specified: one shared timestamp per frame,
contiguous sequence numbers, marker bit on the final fragment only, MTU 1200 measured on the
*sealed* datagram with the AEAD's exact 20-byte expansion (16-byte tag + 4-byte counter; the
nonce is not on the wire) subtracted from every fragment budget.

**Known gap this leaves:** fragments are opaque byte ranges. There is no H.264 FU-A, VP8 payload
descriptor, or AV1 OBU aggregation header — a real Discord receiver needs those, and no receiver
interoperability is claimed.
