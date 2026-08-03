import CLibDave
import Foundation

public enum NativeDAVEMediaType: Equatable, Sendable {
    case audio
    case video

    fileprivate var native: DAVEMediaType {
        switch self {
        case .audio: DAVE_MEDIA_TYPE_AUDIO
        case .video: DAVE_MEDIA_TYPE_VIDEO
        }
    }
}

public enum NativeDAVECodec: Equatable, Sendable {
    case opus
    case vp8
    case vp9
    case h264
    case h265
    case av1

    fileprivate var native: DAVECodec {
        switch self {
        case .opus: DAVE_CODEC_OPUS
        case .vp8: DAVE_CODEC_VP8
        case .vp9: DAVE_CODEC_VP9
        case .h264: DAVE_CODEC_H264
        case .h265: DAVE_CODEC_H265
        case .av1: DAVE_CODEC_AV1
        }
    }
}

public enum NativeDAVECommitOutcome: Equatable, Sendable {
    case applied(rosterMemberIDs: [UInt64])
    case ignored
}

private final class NativeDAVEFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func recordFailure() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    func hasFailed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
}

/// libdave owns neither `userData` nor the transient source/reason C strings.
/// Record only that a failure occurred; native diagnostic text must never cross
/// this boundary into logs, errors, reflection, or persistence.
private let nativeDAVEFailureCallback: DAVEMLSFailureCallback = { _, _, userData in
    guard let userData else { return }
    Unmanaged<NativeDAVEFailureLatch>
        .fromOpaque(userData)
        .takeUnretainedValue()
        .recordFailure()
}

private final class NativeDAVEParticipantStorage {
    private(set) var ratchet: OpaquePointer
    let decryptor: OpaquePointer

    init(ratchet: OpaquePointer, decryptor: OpaquePointer) {
        self.ratchet = ratchet
        self.decryptor = decryptor
    }

    deinit {
        // libdave decryptors borrow their ratchet. Destroy the borrower first.
        daveDecryptorDestroy(decryptor)
        daveKeyRatchetDestroy(ratchet)
    }

    func transition(to newRatchet: OpaquePointer) {
        daveDecryptorTransitionToKeyRatchet(decryptor, newRatchet)
        let oldRatchet = ratchet
        ratchet = newRatchet
        daveKeyRatchetDestroy(oldRatchet)
    }
}

private final class NativeDAVEGroupStorage {
    let session: OpaquePointer
    let encryptor: OpaquePointer
    let failureLatch: NativeDAVEFailureLatch
    var selfRatchet: OpaquePointer?
    var participants: [UInt64: NativeDAVEParticipantStorage] = [:]

    init(
        session: OpaquePointer,
        encryptor: OpaquePointer,
        failureLatch: NativeDAVEFailureLatch
    ) {
        self.session = session
        self.encryptor = encryptor
        self.failureLatch = failureLatch
    }

    deinit {
        // Release every decryptor before any borrowed ratchet or session state.
        participants.removeAll(keepingCapacity: false)
        daveEncryptorDestroy(encryptor)
        if let selfRatchet {
            daveKeyRatchetDestroy(selfRatchet)
        }
        daveSessionDestroy(session)
    }
}

private final class NativeDAVECommitResultStorage {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { daveCommitResultDestroy(raw) }
}

private final class NativeDAVEWelcomeResultStorage {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { daveWelcomeResultDestroy(raw) }
}

/// Actor-owned wrapper around Discord's audited libdave C API.
///
/// This type never enables protocol-zero passthrough. A nonzero session becomes
/// media-capable only after the caller applies valid MLS state and activates a
/// roster containing the local participant. All MLS bytes, ratchets, and media
/// buffers remain process-memory-only and are omitted from diagnostics.
public actor NativeDAVESession: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public static let maximumControlPayloadBytes = 1_048_576
    public static let maximumMediaFrameBytes = 1_048_576
    public static let maximumProtectedFrameBytes = 2_097_152

    private let storage: NativeDAVEGroupStorage
    private let selfUserID: String
    private let selfNumericUserID: UInt64
    private let configuredProtocolVersion: UInt16
    private var activeRoster: [UInt64] = []
    private var pendingCommitRoster: [UInt64]?

    public nonisolated var description: String {
        "NativeDAVESession(credentials: <redacted>, media: encrypted)"
    }

    public nonisolated var debugDescription: String { description }

    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["session": "<redacted>"], displayStyle: .class)
    }

    public init(
        protocolVersion: UInt16,
        groupID: UInt64,
        selfUserID: String,
        authenticationSessionID: String? = nil
    ) throws {
        NativeDAVEPrivacy.installDiscardLogSink()
        let maximum = daveMaxSupportedProtocolVersion()
        guard protocolVersion > 0, protocolVersion <= maximum else {
            throw NativeMediaError.invalidDAVEProtocolVersion(protocolVersion)
        }
        let trimmedUserID = selfUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard groupID > 0,
              !trimmedUserID.isEmpty,
              trimmedUserID.utf8.count <= 64,
              let numericUserID = UInt64(trimmedUserID)
        else {
            throw NativeMediaError.invalidDAVEIdentifier
        }
        if let authenticationSessionID {
            guard !authenticationSessionID.isEmpty,
                  !authenticationSessionID.contains("\0"),
                  authenticationSessionID.utf8.count <= 256
            else {
                throw NativeMediaError.invalidDAVEIdentifier
            }
        }

        let failureLatch = NativeDAVEFailureLatch()
        let failureContext = Unmanaged.passUnretained(failureLatch).toOpaque()
        let session: OpaquePointer? = if let authenticationSessionID {
            authenticationSessionID.withCString {
                daveSessionCreate(
                    nil,
                    $0,
                    nativeDAVEFailureCallback,
                    failureContext
                )
            }
        } else {
            daveSessionCreate(
                nil,
                nil,
                nativeDAVEFailureCallback,
                failureContext
            )
        }
        guard let session else {
            throw NativeMediaError.initializationFailed(component: "libdaveSession")
        }
        guard !failureLatch.hasFailed() else {
            daveSessionDestroy(session)
            throw NativeMediaError.daveMLSFailure(operation: "create-session")
        }
        guard let encryptor = daveEncryptorCreate() else {
            daveSessionDestroy(session)
            throw NativeMediaError.initializationFailed(component: "libdaveEncryptor")
        }

        trimmedUserID.withCString {
            daveSessionInit(session, protocolVersion, groupID, $0)
        }
        guard !failureLatch.hasFailed(),
              daveSessionGetProtocolVersion(session) == protocolVersion
        else {
            daveEncryptorDestroy(encryptor)
            daveSessionDestroy(session)
            throw NativeMediaError.daveMLSFailure(operation: "initialize-session")
        }
        daveEncryptorSetPassthroughMode(encryptor, false)

        self.storage = NativeDAVEGroupStorage(
            session: session,
            encryptor: encryptor,
            failureLatch: failureLatch
        )
        self.selfUserID = trimmedUserID
        self.selfNumericUserID = numericUserID
        self.configuredProtocolVersion = protocolVersion
    }

    public var protocolVersion: UInt16 {
        daveSessionGetProtocolVersion(storage.session)
    }

    public var isMediaReady: Bool {
        !storage.failureLatch.hasFailed()
            && storage.selfRatchet != nil
            && activeRoster.contains(selfNumericUserID)
    }

    public var rosterMemberIDs: [UInt64] {
        storage.failureLatch.hasFailed() ? [] : activeRoster
    }

    public func marshalledKeyPackage() throws -> Data {
        try withMLSFailureCheck(operation: "create-key-package") {
            try takeAllocatedBytes(maximum: Self.maximumControlPayloadBytes) { bytes, length in
                daveSessionGetMarshalledKeyPackage(storage.session, bytes, length)
            }
        }
    }

    public func setExternalSender(_ bytes: Data) throws {
        try requireMLSHealthy(operation: "set-external-sender")
        try validateControlPayload(bytes)
        try withMLSFailureCheck(operation: "set-external-sender") {
            bytes.withUnsafeBytes { raw in
                daveSessionSetExternalSender(
                    storage.session,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                )
            }
        }
    }

    public func processProposals(
        _ proposals: Data,
        recognizedUserIDs: [String]
    ) throws -> Data {
        try requireMLSHealthy(operation: "process-proposals")
        try validateControlPayload(proposals)
        return try withMLSFailureCheck(operation: "process-proposals") {
            try withValidatedUserIDs(recognizedUserIDs) { pointers in
                try takeAllocatedBytes(
                    maximum: Self.maximumControlPayloadBytes
                ) { output, outputLength in
                    proposals.withUnsafeBytes { raw in
                        daveSessionProcessProposals(
                            storage.session,
                            raw.bindMemory(to: UInt8.self).baseAddress,
                            proposals.count,
                            pointers.baseAddress,
                            pointers.count,
                            output,
                            outputLength
                        )
                    }
                }
            }
        }
    }

    public func processCommit(_ commit: Data) throws -> NativeDAVECommitOutcome {
        try requireMLSHealthy(operation: "process-commit")
        try validateControlPayload(commit)
        return try withMLSFailureCheck(operation: "process-commit") {
            let rawResult = commit.withUnsafeBytes { raw in
                daveSessionProcessCommit(
                    storage.session,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    commit.count
                )
            }
            guard let rawResult else {
                throw NativeMediaError.daveCommitFailed
            }
            let result = NativeDAVECommitResultStorage(rawResult)
            guard !daveCommitResultIsFailed(result.raw) else {
                pendingCommitRoster = nil
                throw NativeMediaError.daveCommitFailed
            }
            if daveCommitResultIsIgnored(result.raw) {
                pendingCommitRoster = nil
                return .ignored
            }
            do {
                let changedMemberIDs = try takeRosterMemberIDs { ids, length in
                    daveCommitResultGetRosterMemberIds(result.raw, ids, length)
                }
                var changes: [UInt64: Bool] = [:]
                changes.reserveCapacity(changedMemberIDs.count)
                for memberID in changedMemberIDs {
                    // ReplaceState exposes only changed members. A nonempty
                    // signature means add/change; an empty signature means the
                    // member was removed. Retain only that presence bit.
                    let isPresent = try !takeAllocatedBytes(
                        maximum: Self.maximumControlPayloadBytes
                    ) { bytes, length in
                        daveCommitResultGetRosterMemberSignature(
                            result.raw,
                            memberID,
                            bytes,
                            length
                        )
                    }.isEmpty
                    changes[memberID] = isPresent
                }
                let roster = Self.rosterAfterCommit(
                    current: activeRoster,
                    changes: changes
                )
                _ = try validateRoster(memberIDs: roster)
                // Commit processing mutates the MLS epoch, but Discord does
                // not authorize media-ratchet publication until the matching
                // Execute Transition. Retain the current encryptor/decryptor
                // ratchets and stage only the candidate roster here.
                pendingCommitRoster = roster
                return .applied(rosterMemberIDs: roster)
            } catch {
                invalidateMediaReadiness()
                throw error
            }
        }
    }

    /// Activates the ratchets prepared by the most recent applied Commit.
    /// Callers must correlate this operation with Discord's Execute Transition.
    public func activatePendingCommit() throws {
        try requireMLSHealthy(operation: "activate-commit")
        guard let pendingCommitRoster else {
            throw NativeMediaError.daveCommitFailed
        }
        do {
            try activateRoster(memberIDs: pendingCommitRoster)
            self.pendingCommitRoster = nil
        } catch {
            self.pendingCommitRoster = nil
            invalidateMediaReadiness()
            throw error
        }
    }

    public func processWelcome(
        _ welcome: Data,
        recognizedUserIDs: [String]
    ) throws -> [UInt64] {
        try requireMLSHealthy(operation: "process-welcome")
        try validateControlPayload(welcome)
        return try withMLSFailureCheck(operation: "process-welcome") {
            try withValidatedUserIDs(recognizedUserIDs) { pointers in
                let rawResult = welcome.withUnsafeBytes { raw in
                    daveSessionProcessWelcome(
                        storage.session,
                        raw.bindMemory(to: UInt8.self).baseAddress,
                        welcome.count,
                        pointers.baseAddress,
                        pointers.count
                    )
                }
                guard let rawResult else {
                    invalidateMediaReadiness()
                    throw NativeMediaError.daveWelcomeFailed
                }
                let result = NativeDAVEWelcomeResultStorage(rawResult)
                do {
                    let roster = try takeRosterMemberIDs { ids, length in
                        daveWelcomeResultGetRosterMemberIds(result.raw, ids, length)
                    }
                    try activateRoster(memberIDs: roster)
                    return roster
                } catch {
                    invalidateMediaReadiness()
                    throw error
                }
            }
        }
    }

    /// Refreshes borrowed ratchets only after the gateway/MLS transition is accepted.
    /// The update is built fully before it replaces the active roster.
    public func activateRoster(memberIDs: [UInt64]) throws {
        try withMLSFailureCheck(operation: "activate-roster") {
            try activateRosterUnchecked(memberIDs: memberIDs)
        }
    }

    private func activateRosterUnchecked(memberIDs: [UInt64]) throws {
        let unique = try validateRoster(memberIDs: memberIDs)

        enum PreparedParticipant {
            case retained(ratchet: OpaquePointer)
            case added(NativeDAVEParticipantStorage)
        }

        var preparedSelfRatchet: OpaquePointer?
        var preparedParticipants: [UInt64: PreparedParticipant] = [:]
        do {
            for memberID in unique {
                let userID = String(memberID)
                guard let ratchet = userID.withCString({
                    daveSessionGetKeyRatchet(storage.session, $0)
                }) else {
                    throw NativeMediaError.daveParticipantUnavailable
                }
                if memberID == selfNumericUserID {
                    preparedSelfRatchet = ratchet
                } else if storage.participants[memberID] != nil {
                    preparedParticipants[memberID] = .retained(ratchet: ratchet)
                } else {
                    guard let decryptor = daveDecryptorCreate() else {
                        daveKeyRatchetDestroy(ratchet)
                        throw NativeMediaError.initializationFailed(component: "libdaveDecryptor")
                    }
                    daveDecryptorTransitionToPassthroughMode(decryptor, false)
                    daveDecryptorTransitionToKeyRatchet(decryptor, ratchet)
                    preparedParticipants[memberID] = .added(
                        NativeDAVEParticipantStorage(
                            ratchet: ratchet,
                            decryptor: decryptor
                        )
                    )
                }
            }
        } catch {
            for prepared in preparedParticipants.values {
                if case .retained(let ratchet) = prepared {
                    daveKeyRatchetDestroy(ratchet)
                }
            }
            preparedParticipants.removeAll(keepingCapacity: false)
            if let preparedSelfRatchet {
                daveKeyRatchetDestroy(preparedSelfRatchet)
            }
            throw error
        }

        guard let preparedSelfRatchet else {
            throw NativeMediaError.daveParticipantUnavailable
        }
        daveEncryptorSetKeyRatchet(storage.encryptor, preparedSelfRatchet)
        let oldSelfRatchet = storage.selfRatchet
        let retainedIDs = Set(preparedParticipants.keys)
        let removedIDs = storage.participants.keys.filter { !retainedIDs.contains($0) }
        for memberID in removedIDs {
            storage.participants.removeValue(forKey: memberID)
        }
        for (memberID, prepared) in preparedParticipants {
            switch prepared {
            case .retained(let ratchet):
                storage.participants[memberID]?.transition(to: ratchet)
            case .added(let participant):
                storage.participants[memberID] = participant
            }
        }
        storage.selfRatchet = preparedSelfRatchet
        activeRoster = unique
        if let oldSelfRatchet {
            daveKeyRatchetDestroy(oldSelfRatchet)
        }
    }

    private func validateRoster(memberIDs: [UInt64]) throws -> [UInt64] {
        let unique = Array(Set(memberIDs)).sorted()
        guard !unique.isEmpty, unique.count <= 1_024, unique.contains(selfNumericUserID) else {
            throw NativeMediaError.daveParticipantUnavailable
        }
        return unique
    }

    public func protect(
        _ frame: Data,
        mediaType: NativeDAVEMediaType,
        codec: NativeDAVECodec,
        ssrc: UInt32
    ) throws -> Data {
        try requireMLSHealthy(operation: "protect")
        guard isMediaReady else {
            throw NativeMediaError.daveParticipantUnavailable
        }
        try validateMediaFrame(frame)
        daveEncryptorAssignSsrcToCodec(storage.encryptor, ssrc, codec.native)
        let capacity = daveEncryptorGetMaxCiphertextByteSize(
            storage.encryptor,
            mediaType.native,
            frame.count
        )
        guard capacity >= frame.count, capacity <= Self.maximumProtectedFrameBytes else {
            throw NativeMediaError.daveFrameTooLarge(
                actual: capacity,
                maximum: Self.maximumProtectedFrameBytes
            )
        }
        var output = Data(count: capacity)
        var written = 0
        let result = output.withUnsafeMutableBytes { outputBytes in
            frame.withUnsafeBytes { frameBytes in
                daveEncryptorEncrypt(
                    storage.encryptor,
                    mediaType.native,
                    ssrc,
                    frameBytes.bindMemory(to: UInt8.self).baseAddress,
                    frame.count,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    capacity,
                    &written
                )
            }
        }
        guard result == DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS, written <= capacity else {
            try requireMLSHealthy(operation: "protect")
            throw NativeMediaError.daveFailure(operation: "protect", code: result.rawValue)
        }
        try requireMLSHealthy(operation: "protect")
        output.removeSubrange(written..<output.count)
        return output
    }

    public func unprotect(
        _ frame: Data,
        mediaType: NativeDAVEMediaType,
        senderID: UInt64
    ) throws -> Data {
        try requireMLSHealthy(operation: "unprotect")
        guard let participant = storage.participants[senderID] else {
            throw NativeMediaError.daveParticipantUnavailable
        }
        guard !frame.isEmpty, frame.count <= Self.maximumProtectedFrameBytes else {
            throw NativeMediaError.daveFrameTooLarge(
                actual: frame.count,
                maximum: Self.maximumProtectedFrameBytes
            )
        }
        let capacity = daveDecryptorGetMaxPlaintextByteSize(
            participant.decryptor,
            mediaType.native,
            frame.count
        )
        guard capacity <= Self.maximumMediaFrameBytes else {
            throw NativeMediaError.daveFrameTooLarge(
                actual: capacity,
                maximum: Self.maximumMediaFrameBytes
            )
        }
        var output = Data(count: capacity)
        var written = 0
        let result = output.withUnsafeMutableBytes { outputBytes in
            frame.withUnsafeBytes { frameBytes in
                daveDecryptorDecrypt(
                    participant.decryptor,
                    mediaType.native,
                    frameBytes.bindMemory(to: UInt8.self).baseAddress,
                    frame.count,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    capacity,
                    &written
                )
            }
        }
        guard result == DAVE_DECRYPTOR_RESULT_CODE_SUCCESS, written <= capacity else {
            try requireMLSHealthy(operation: "unprotect")
            throw NativeMediaError.daveFailure(operation: "unprotect", code: result.rawValue)
        }
        try requireMLSHealthy(operation: "unprotect")
        output.removeSubrange(written..<output.count)
        return output
    }

    private func validateControlPayload(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= Self.maximumControlPayloadBytes else {
            throw NativeMediaError.daveFrameTooLarge(
                actual: bytes.count,
                maximum: Self.maximumControlPayloadBytes
            )
        }
    }

    private func withMLSFailureCheck<Result>(
        operation: String,
        _ body: () throws -> Result
    ) throws -> Result {
        try requireMLSHealthy(operation: operation)
        let result: Result
        do {
            result = try body()
        } catch {
            if storage.failureLatch.hasFailed() {
                try requireMLSHealthy(operation: operation)
            }
            throw error
        }
        try requireMLSHealthy(operation: operation)
        return result
    }

    private func requireMLSHealthy(operation: String) throws {
        guard !storage.failureLatch.hasFailed() else {
            invalidateMediaReadiness()
            throw NativeMediaError.daveMLSFailure(operation: operation)
        }
    }

    static func rosterAfterCommit(
        current: [UInt64],
        changes: [UInt64: Bool]
    ) -> [UInt64] {
        var roster = Set(current)
        for (memberID, isPresent) in changes {
            if isPresent {
                roster.insert(memberID)
            } else {
                roster.remove(memberID)
            }
        }
        return roster.sorted()
    }

    private func invalidateMediaReadiness() {
        // The encryptor still borrows its last ratchet, so retain that handle
        // until replacement or teardown. Clearing the roster gates every media
        // call and destroying participant decryptors prevents stale-epoch use.
        storage.participants.removeAll(keepingCapacity: false)
        activeRoster.removeAll(keepingCapacity: false)
        pendingCommitRoster = nil
    }

    private func validateMediaFrame(_ frame: Data) throws {
        guard !frame.isEmpty, frame.count <= Self.maximumMediaFrameBytes else {
            throw NativeMediaError.daveFrameTooLarge(
                actual: frame.count,
                maximum: Self.maximumMediaFrameBytes
            )
        }
    }

    private func takeAllocatedBytes(
        maximum: Int,
        _ operation: (
            UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
            UnsafeMutablePointer<Int>
        ) -> Void
    ) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        operation(&bytes, &length)
        defer { daveFree(bytes) }
        guard length >= 0, length <= maximum else {
            throw NativeMediaError.daveFrameTooLarge(actual: length, maximum: maximum)
        }
        guard length == 0 || bytes != nil else {
            throw NativeMediaError.daveFailure(operation: "output", code: 0)
        }
        return bytes.map { Data(bytes: $0, count: length) } ?? Data()
    }

    private func takeRosterMemberIDs(
        _ operation: (
            UnsafeMutablePointer<UnsafeMutablePointer<UInt64>?>,
            UnsafeMutablePointer<Int>
        ) -> Void
    ) throws -> [UInt64] {
        var ids: UnsafeMutablePointer<UInt64>?
        var count = 0
        operation(&ids, &count)
        defer { daveFree(ids) }
        guard (0...1_024).contains(count), count == 0 || ids != nil else {
            throw NativeMediaError.daveParticipantUnavailable
        }
        guard let ids else { return [] }
        return Array(UnsafeBufferPointer(start: ids, count: count))
    }

    private func withValidatedUserIDs<Result>(
        _ userIDs: [String],
        _ body: (UnsafeMutableBufferPointer<UnsafePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        guard userIDs.count <= 1_024 else {
            throw NativeMediaError.invalidDAVEIdentifier
        }
        let normalized = try userIDs.map { userID in
            let value = userID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 64, UInt64(value) != nil else {
                throw NativeMediaError.invalidDAVEIdentifier
            }
            return value
        }
        let allocated = normalized.map { strdup($0) }
        defer {
            for pointer in allocated { free(pointer) }
        }
        guard allocated.allSatisfy({ $0 != nil }) else {
            throw NativeMediaError.initializationFailed(component: "userIdentifierBuffer")
        }
        var pointers: [UnsafePointer<CChar>?] = allocated.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer)
        }
    }
}
