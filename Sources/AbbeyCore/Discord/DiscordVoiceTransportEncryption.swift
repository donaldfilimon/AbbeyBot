/// Discord Voice RTPSIZE transport modes supported by the portable media layer.
///
/// This type names and orchestrates AEAD operations; it does not implement the
/// cryptographic primitive. Production callers must inject an audited native
/// implementation through ``DiscordVoiceAEADPrimitive``.
public enum DiscordVoiceTransportMode: String, CaseIterable, Equatable, Sendable {
    case aeadXChaCha20Poly1305RTPSIZE = "aead_xchacha20_poly1305_rtpsize"
    case aeadAES256GCMRTPSIZE = "aead_aes256_gcm_rtpsize"

    public var nonceLength: Int {
        switch self {
        case .aeadXChaCha20Poly1305RTPSIZE: 24
        case .aeadAES256GCMRTPSIZE: 12
        }
    }

    /// Prefer hardware-backed AES when both peers advertise it and the local
    /// primitive reports support. XChaCha20-Poly1305 is the mandatory fallback.
    public static func negotiate(
        advertisedModes: [String],
        aes256GCMAvailable: Bool
    ) throws -> Self {
        let advertised = Set(advertisedModes)
        if aes256GCMAvailable, advertised.contains(Self.aeadAES256GCMRTPSIZE.rawValue) {
            return .aeadAES256GCMRTPSIZE
        }
        if advertised.contains(Self.aeadXChaCha20Poly1305RTPSIZE.rawValue) {
            return .aeadXChaCha20Poly1305RTPSIZE
        }
        throw DiscordVoiceTransportEncryptionError.noCompatibleMode
    }
}

public enum DiscordVoiceTransportEncryptionError: Error, Equatable, Sendable, CustomStringConvertible {
    case noCompatibleMode
    case primitiveModeMismatch(expected: DiscordVoiceTransportMode, actual: DiscordVoiceTransportMode)
    case invalidKeyLength(expected: Int, actual: Int)
    case invalidAuthenticationTagLength(expected: Int, actual: Int)
    case invalidSourceCapacity(Int)
    case invalidReplayWindowSize(Int)
    case sourceCapacityExceeded(Int)
    case packetMissingProtectedPayload
    case authenticationFailed
    case encryptionFailed
    case duplicateNonce(ssrc: UInt32, nonce: UInt32)
    case nonceTooOld(ssrc: UInt32, nonce: UInt32)
    case sendCounterExhausted

    public var description: String {
        switch self {
        case .noCompatibleMode:
            return "No compatible Discord Voice RTPSIZE transport mode was advertised"
        case .primitiveModeMismatch(let expected, let actual):
            return "AEAD primitive mode \(actual.rawValue) does not match negotiated mode \(expected.rawValue)"
        case .invalidKeyLength(let expected, let actual):
            return "Discord Voice transport key must contain \(expected) bytes; got \(actual)"
        case .invalidAuthenticationTagLength(let expected, let actual):
            return "Discord Voice AEAD tag must contain \(expected) bytes; got \(actual)"
        case .invalidSourceCapacity(let capacity):
            return "Discord Voice receive source capacity must be positive; got \(capacity)"
        case .invalidReplayWindowSize(let size):
            return "Discord Voice nonce replay window must be in 1...64; got \(size)"
        case .sourceCapacityExceeded(let capacity):
            return "Discord Voice receive source capacity \(capacity) was reached"
        case .packetMissingProtectedPayload:
            return "Discord Voice RTPSIZE packet has no authenticated protected payload"
        case .authenticationFailed:
            return "Discord Voice RTPSIZE packet authentication failed"
        case .encryptionFailed:
            return "Discord Voice RTPSIZE packet encryption failed"
        case .duplicateNonce(let ssrc, let nonce):
            return "Discord Voice RTPSIZE packet repeats nonce \(nonce) for SSRC \(ssrc)"
        case .nonceTooOld(let ssrc, let nonce):
            return "Discord Voice RTPSIZE nonce \(nonce) is outside the replay window for SSRC \(ssrc)"
        case .sendCounterExhausted:
            return "Discord Voice RTPSIZE send counter is exhausted; rekey before sending again"
        }
    }
}

/// An injected, audited AEAD implementation used by the portable RTPSIZE layer.
///
/// Implementations must return `ciphertext || tag` from `seal` and authenticate
/// before returning plaintext from `open`. The transport supplies the exact
/// 32-byte key, mode-specific nonce, and clear RTP header as associated data.
public protocol DiscordVoiceAEADPrimitive: Sendable {
    var mode: DiscordVoiceTransportMode { get }
    var authenticationTagLength: Int { get }

    func seal(
        plaintext: [UInt8],
        key: [UInt8],
        nonce: [UInt8],
        authenticating associatedData: [UInt8]
    ) async throws -> [UInt8]

    func open(
        ciphertextAndTag: [UInt8],
        key: [UInt8],
        nonce: [UInt8],
        authenticating associatedData: [UInt8]
    ) async throws -> [UInt8]
}

private struct DiscordVoiceNonceReplayWindow: Sendable {
    enum Decision: Equatable, Sendable {
        case accept
        case duplicate
        case tooOld
    }

    let size: Int
    private(set) var highest: UInt32?
    private var bitmap: UInt64 = 0

    init(size: Int) {
        self.size = size
    }

    func decision(for nonce: UInt32) -> Decision {
        guard let highest else { return .accept }
        if nonce > highest { return .accept }

        let distance = highest - nonce
        guard distance < UInt32(size) else { return .tooOld }
        return bitmap & (UInt64(1) << UInt64(distance)) == 0 ? .accept : .duplicate
    }

    mutating func record(_ nonce: UInt32) {
        guard let highest else {
            self.highest = nonce
            bitmap = 1
            return
        }

        if nonce > highest {
            let distance = nonce - highest
            bitmap = distance >= UInt32(size) ? 1 : (bitmap << UInt64(distance)) | 1
            if size < 64 {
                bitmap &= (UInt64(1) << UInt64(size)) - 1
            }
            self.highest = nonce
            return
        }

        let distance = highest - nonce
        precondition(distance < UInt32(size))
        bitmap |= UInt64(1) << UInt64(distance)
    }
}

/// Single-owner RTPSIZE encryption, framing, and authenticated replay control.
///
/// The four-byte big-endian counter is appended to each packet. The same bytes
/// occupy the first four bytes of the AEAD nonce; every remaining nonce byte is
/// zero. Send counters never wrap, and receive counters are tracked separately
/// for each SSRC only after successful authentication.
public actor DiscordVoiceTransportEncryption {
    public static let keyLength = 32
    public static let authenticationTagLength = 16
    public static let counterSuffixLength = 4

    public let mode: DiscordVoiceTransportMode
    public let sourceCapacity: Int
    public let replayWindowSize: Int
    public private(set) var nextSendCounter: UInt32?

    private let key: [UInt8]
    private let primitive: any DiscordVoiceAEADPrimitive
    private let rtpCodec: DiscordVoiceRTPCodec
    private var receiveWindows: [UInt32: DiscordVoiceNonceReplayWindow] = [:]

    public init(
        mode: DiscordVoiceTransportMode,
        key: [UInt8],
        primitive: any DiscordVoiceAEADPrimitive,
        initialSendCounter: UInt32 = 0,
        sourceCapacity: Int = 256,
        replayWindowSize: Int = 64
    ) throws {
        guard primitive.mode == mode else {
            throw DiscordVoiceTransportEncryptionError.primitiveModeMismatch(
                expected: mode,
                actual: primitive.mode
            )
        }
        guard key.count == Self.keyLength else {
            throw DiscordVoiceTransportEncryptionError.invalidKeyLength(
                expected: Self.keyLength,
                actual: key.count
            )
        }
        guard primitive.authenticationTagLength == Self.authenticationTagLength else {
            throw DiscordVoiceTransportEncryptionError.invalidAuthenticationTagLength(
                expected: Self.authenticationTagLength,
                actual: primitive.authenticationTagLength
            )
        }
        guard sourceCapacity > 0 else {
            throw DiscordVoiceTransportEncryptionError.invalidSourceCapacity(sourceCapacity)
        }
        guard (1...64).contains(replayWindowSize) else {
            throw DiscordVoiceTransportEncryptionError.invalidReplayWindowSize(replayWindowSize)
        }

        self.mode = mode
        self.key = key
        self.primitive = primitive
        self.nextSendCounter = initialSendCounter
        self.sourceCapacity = sourceCapacity
        self.replayWindowSize = replayWindowSize
        self.rtpCodec = try DiscordVoiceRTPCodec()
        self.receiveWindows.reserveCapacity(sourceCapacity)
    }

    /// Encrypts only the RTP body. The full variable-length RTP header stays
    /// clear and is authenticated as AEAD associated data.
    public func seal(_ plaintextPacket: [UInt8]) async throws -> [UInt8] {
        guard let counter = nextSendCounter else {
            throw DiscordVoiceTransportEncryptionError.sendCounterExhausted
        }

        // Reserve the nonce before suspension. Even a cancelled or failed
        // primitive call cannot cause this transport instance to reuse it.
        nextSendCounter = counter == UInt32.max ? nil : counter + 1

        let layout = try rtpCodec.plaintextLayout(in: plaintextPacket)
        let associatedData = Array(plaintextPacket[layout.headerRange])
        let protectedPlaintext = Array(plaintextPacket[layout.headerRange.upperBound...])

        let ciphertextAndTag: [UInt8]
        do {
            ciphertextAndTag = try await primitive.seal(
                plaintext: protectedPlaintext,
                key: key,
                nonce: makeNonce(counter),
                authenticating: associatedData
            )
        } catch {
            throw DiscordVoiceTransportEncryptionError.encryptionFailed
        }
        guard ciphertextAndTag.count == protectedPlaintext.count + Self.authenticationTagLength else {
            throw DiscordVoiceTransportEncryptionError.encryptionFailed
        }

        return associatedData + ciphertextAndTag + counterBytes(counter)
    }

    /// Authenticates and decrypts an RTPSIZE packet. Replay state is checked
    /// before the native call but committed only after authentication succeeds.
    public func open(_ protectedPacket: [UInt8]) async throws -> [UInt8] {
        let layout = try rtpCodec.protectedLayout(
            in: protectedPacket,
            trailingByteCount: Self.counterSuffixLength
        )
        guard layout.protectedPayloadRange.count >= Self.authenticationTagLength else {
            throw DiscordVoiceTransportEncryptionError.packetMissingProtectedPayload
        }

        let header = try rtpCodec.decodeHeader(from: protectedPacket)
        let counter = readCounter(Array(protectedPacket[layout.trailingRange]))
        try validateReplay(ssrc: header.ssrc, counter: counter)

        let associatedData = Array(protectedPacket[layout.headerRange])
        let ciphertextAndTag = Array(protectedPacket[layout.protectedPayloadRange])
        let plaintext: [UInt8]
        do {
            plaintext = try await primitive.open(
                ciphertextAndTag: ciphertextAndTag,
                key: key,
                nonce: makeNonce(counter),
                authenticating: associatedData
            )
        } catch {
            throw DiscordVoiceTransportEncryptionError.authenticationFailed
        }

        // The actor can be re-entered while authentication is suspended. A
        // second check prevents concurrent duplicate opens from both succeeding.
        try validateReplay(ssrc: header.ssrc, counter: counter)

        let plaintextPacket = associatedData + plaintext
        do {
            _ = try rtpCodec.plaintextLayout(in: plaintextPacket)
        } catch {
            throw DiscordVoiceTransportEncryptionError.authenticationFailed
        }
        try recordAuthenticatedCounter(ssrc: header.ssrc, counter: counter)
        return plaintextPacket
    }

    private func validateReplay(ssrc: UInt32, counter: UInt32) throws {
        guard let window = receiveWindows[ssrc] else {
            guard receiveWindows.count < sourceCapacity else {
                throw DiscordVoiceTransportEncryptionError.sourceCapacityExceeded(sourceCapacity)
            }
            return
        }

        switch window.decision(for: counter) {
        case .accept:
            return
        case .duplicate:
            throw DiscordVoiceTransportEncryptionError.duplicateNonce(ssrc: ssrc, nonce: counter)
        case .tooOld:
            throw DiscordVoiceTransportEncryptionError.nonceTooOld(ssrc: ssrc, nonce: counter)
        }
    }

    private func recordAuthenticatedCounter(ssrc: UInt32, counter: UInt32) throws {
        var window: DiscordVoiceNonceReplayWindow
        if let existing = receiveWindows[ssrc] {
            window = existing
        } else {
            guard receiveWindows.count < sourceCapacity else {
                throw DiscordVoiceTransportEncryptionError.sourceCapacityExceeded(sourceCapacity)
            }
            window = DiscordVoiceNonceReplayWindow(size: replayWindowSize)
        }
        window.record(counter)
        receiveWindows[ssrc] = window
    }

    private func makeNonce(_ counter: UInt32) -> [UInt8] {
        counterBytes(counter) + Array(repeating: 0, count: mode.nonceLength - Self.counterSuffixLength)
    }

    private func counterBytes(_ counter: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: counter >> 24),
            UInt8(truncatingIfNeeded: counter >> 16),
            UInt8(truncatingIfNeeded: counter >> 8),
            UInt8(truncatingIfNeeded: counter),
        ]
    }

    private func readCounter(_ bytes: [UInt8]) -> UInt32 {
        precondition(bytes.count == Self.counterSuffixLength)
        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }
}
