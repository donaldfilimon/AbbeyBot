# Native media dependencies

Status: opt-in plumbing only. These native adapters do not make Discord voice or DAVE media a
shipped product feature. Normal desktop, server, and CLI package graphs do not include them.

## Audited immutable inputs

| Dependency | Immutable source | SHA-256 |
|---|---|---|
| libdave macOS ARM64 | `v1.1.1/cpp`, commit `52cd56dc550f447fb354b3a06c9e2d2e2a4309c6`, `libdave-macOS-ARM64-boringssl.zip` | `ff8ae20332b4553cb61989cbcecd8dc4224edfc0ab9afdf7e23c1a9aa5ed748a` |
| libdave macOS X64 | same tag/commit, `libdave-macOS-X64-boringssl.zip` | `8588ba9e664f659b3b143ddccd2edccf4432de8150698e3c1ad401a9149ea851` |
| libdave Linux ARM64 | same tag/commit, `libdave-Linux-ARM64-boringssl.zip` | `2848ca62da5c8303626cfa410827f37735455f614256311fc320b35c7c6a1975` |
| libdave Linux X64 | same tag/commit, `libdave-Linux-X64-boringssl.zip` | `2470a131dbf39a820d893ba3d6f01373fc597868caffd6a30a8746e441ed5ede` |
| Opus | `opus-1.6.1.tar.gz` | `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1` |
| libsodium | `libsodium-1.0.22.tar.gz` | `adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349` |

The bootstrap uses HTTPS downloads, verifies each full SHA-256 before extraction, rejects unknown
OS/architecture pairs, and keeps its build workspace below the selected prefix. Its cache defaults
below that prefix and may be moved only with an explicit absolute `ABBEY_NATIVE_CACHE`. It does not
invoke CMake or vcpkg from SwiftPM.

## Bootstrap and build

```bash
bash Scripts/bootstrap-native-media.sh --dry-run
bash Scripts/bootstrap-native-media.sh
source "${TMPDIR}/AbbeyBot.native/v1/abbey-native.env"
unset TOOLCHAINS
/usr/bin/xcrun --toolchain default swift test \
  --build-path "${TMPDIR}/AbbeyBot.native.build" \
  --filter AbbeyMediaNativeTests
```

Set an absolute `ABBEY_NATIVE_PREFIX` before bootstrap to choose another contained prefix. The
generated `abbey-native.env` enables `ABBEY_NATIVE_MEDIA=1` and supplies `PKG_CONFIG_PATH`,
`LIBRARY_PATH`, and the platform runtime-library path. Without that opt-in, `Package.swift` does not
declare `CLibDave`, `COpus`, `CSodium`, `AbbeyMediaNative`, or its test target.

## API boundary

- libdave: audited pin constants, runtime maximum protocol query, and protocol-zero encryptor /
  decryptor passthrough lifecycle only. No MLS, roster, ratchet, or nonzero-DAVE claim is exposed.
- libsodium: initialization and AES availability queries plus an actor-owned XChaCha20-Poly1305 or
  AES-256-GCM key. `NativeAEAD(mode:key:)` requires an exact 32-byte key. Every `seal` / `open`
  call requires the complete, exact 24-byte XChaCha or 12-byte AES nonce and exchanges only the
  `Sendable` `NativeSealedPacket`. The native layer assigns no meaning to nonce bytes and maintains
  no Discord counter state; RTPSIZE's first-four-byte counter layout belongs to its packet caller.
  Keys are cleared with `sodium_memzero`; errors never include keys or payloads.
- Opus: actor-owned encoder/decoder handles fixed to 48 kHz stereo, 20 ms frames, with bounded packet
  lengths and explicit packet-loss concealment.
- `NativeDiscordVoiceAEADPrimitive`: the native adapter for AbbeyCore's portable
  `DiscordVoiceTransportEncryption`. It maps the negotiated mode and forwards the exact key, nonce,
  RTP payload, and authenticated header without constructing counters or packet framing itself. Its
  actor caches one native key context after first use, compares later keys with `sodium_memcmp`, and
  fails closed with a redacted mismatch error instead of reallocating key storage per packet.

Opaque native handles remain private, have matched destroy functions, and are held by actors through
final non-`Sendable` storage objects.

On macOS, the verified libdave copy receives an absolute install name for the explicitly selected
prefix and is re-signed ad hoc. This keeps SwiftPM/XCTest loading deterministic even when its helper
sanitizes `DYLD_LIBRARY_PATH`; archive verification happens before the local install-name change.

## Complete licenses and notices

The verified libdave release contains four complete notices named `libdave`, `nlohmann-json`,
`boringssl`, and `mlspp`. The bootstrap copies all four byte-for-byte into
`$ABBEY_NATIVE_PREFIX/share/licenses/libdave-1.1.1/`. It also copies the complete `COPYING` file from
the verified Opus source archive and complete `LICENSE` file from the verified libsodium source
archive into adjacent versioned directories. Do not replace these with shortened summaries when
packaging or redistributing the native libraries.

License summary only (the copied upstream files are authoritative): libdave and nlohmann-json are
MIT; the bundled BoringSSL notice contains the applicable OpenSSL, SSLeay, ISC, fiat-crypto, Go, and
Chromium terms; mlspp is BSD-2-Clause; Opus uses its upstream BSD-style terms; libsodium uses ISC.
