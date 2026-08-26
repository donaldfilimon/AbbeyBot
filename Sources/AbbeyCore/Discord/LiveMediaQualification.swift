import Crypto
import Foundation

public enum LiveMediaCapability: String, Codable, CaseIterable, Sendable {
    case audioSend, audioReceive, cameraSend, cameraReceive, screenSend, screenReceive
}

public enum LiveMediaEpochCloseReason: String, Codable, Sendable {
    case operatorStop, participantChanged, participantUnidentified
    case managerAuthorizationChanged, consentRevoked, connectionReplaced
    case sourceInterrupted, applicationBackgrounded, emergencyStop
}

public struct DiscordVoiceParticipantSnapshot: Equatable, Sendable {
    public var count: Int
    public var participantDigests: Set<String>
    /// True only after the main Gateway supplied a complete guild voice-state
    /// snapshot and every subsequent entrant could be tracked. Incremental
    /// VOICE_STATE_UPDATE events alone can never establish completeness.
    public var isComplete: Bool

    public init(
        count: Int,
        participantDigests: Set<String>,
        isComplete: Bool = true
    ) {
        self.count = count
        self.participantDigests = participantDigests
        self.isComplete = isComplete
    }
}

public struct LiveMediaConsentEpoch: Codable, Equatable, Sendable {
    public var hash: String
    public var guildIDDigest: String
    public var participantSetDigest: String
    public var guildAuthorizationClass: String
    public var participantCount: Int
    public var openedAt: Date
    public var capabilities: Set<LiveMediaCapability>
}

/// Content-free authority passed into one Voice Gateway construction. It is
/// valid only for the exact guild digest, participant-set digest, epoch, codec,
/// DAVE version, and capability set approved by the coordinator.
public final class DiscordVoiceQualificationLease: @unchecked Sendable {
    public let consentEpochHash: String
    public let guildIDDigest: String
    public let participantSetDigest: String
    public let capabilities: Set<LiveMediaCapability>
    public let daveProtocolVersion: Int
    public let codec: String

    private enum State { case fresh, admitted, constructed, revoked }
    private let lock = NSLock()
    private var state = State.fresh

    fileprivate init(
        consentEpochHash: String,
        guildIDDigest: String,
        participantSetDigest: String,
        capabilities: Set<LiveMediaCapability>,
        daveProtocolVersion: Int,
        codec: String
    ) {
        self.consentEpochHash = consentEpochHash
        self.guildIDDigest = guildIDDigest
        self.participantSetDigest = participantSetDigest
        self.capabilities = capabilities
        self.daveProtocolVersion = daveProtocolVersion
        self.codec = codec
    }

    public func qualifies(guildID: String) -> Bool {
        guard isStructurallyValid, Self.digest(guildID) == guildIDDigest else { return false }
        lock.lock()
        defer { lock.unlock() }
        return state == .fresh
    }

    package func admit(guildID: String) -> Bool {
        guard isStructurallyValid, Self.digest(guildID) == guildIDDigest else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard state == .fresh else { return false }
        state = .admitted
        return true
    }

    package func consumeForConstruction() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .admitted else { return false }
        state = .constructed
        return true
    }

    fileprivate func revoke() {
        lock.lock()
        state = .revoked
        lock.unlock()
    }

    public var isStructurallyValid: Bool {
        Self.isDigest(consentEpochHash)
            && Self.isDigest(guildIDDigest)
            && Self.isDigest(participantSetDigest)
            && daveProtocolVersion == 1
            && codec == "H264"
            && !capabilities.isEmpty
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

public struct LiveMediaQualificationSnapshot: Codable, Equatable, Sendable {
    public var canaryEnabled: Bool
    public var epoch: LiveMediaConsentEpoch?
    public var lastCloseReason: LiveMediaEpochCloseReason?
    public var daveProtocolVersion: Int?
    public var codec: String?

    public init(
        canaryEnabled: Bool,
        epoch: LiveMediaConsentEpoch?,
        lastCloseReason: LiveMediaEpochCloseReason?,
        daveProtocolVersion: Int?,
        codec: String?
    ) {
        self.canaryEnabled = canaryEnabled
        self.epoch = epoch
        self.lastCloseReason = lastCloseReason
        self.daveProtocolVersion = daveProtocolVersion
        self.codec = codec
    }
}

public struct LiveMediaQualificationReceipt: Codable, Equatable, Sendable {
    public var candidateCommit: String
    public var dependencyRevisions: [String: String]
    public var guildAuthorizationClass: String
    public var consentEpochHash: String
    public var daveProtocolVersion: Int
    public var selectedCodec: String
    public var startedAt: Date
    public var completedAt: Date
    public var outcomes: [String: Bool]

    public static let requiredPromotionOutcomes: Set<String> = [
        "join", "speak", "hear", "reconnect", "leave", "receiveDefaultOff",
        "cameraSend", "cameraReceive", "goLiveSend", "goLiveReceive",
        "sourceSwitch", "interruptionRecovery", "emergencyStop",
        "reconsentAfterParticipantChange",
    ]

    public init(
        candidateCommit: String,
        dependencyRevisions: [String: String],
        guildAuthorizationClass: String,
        consentEpochHash: String,
        daveProtocolVersion: Int,
        selectedCodec: String,
        startedAt: Date,
        completedAt: Date,
        outcomes: [String: Bool]
    ) {
        self.candidateCommit = candidateCommit
        self.dependencyRevisions = dependencyRevisions
        self.guildAuthorizationClass = guildAuthorizationClass
        self.consentEpochHash = consentEpochHash
        self.daveProtocolVersion = daveProtocolVersion
        self.selectedCodec = selectedCodec
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcomes = outcomes
    }

    /// A receipt is promotion evidence only when it is content-free, bound to
    /// immutable revisions and the consent epoch, and every witnessed outcome
    /// is present and true. Merely serializing a receipt never qualifies media.
    public func validatedForPromotion(
        requiredOutcomes: Set<String> = Self.requiredPromotionOutcomes
    ) throws -> Self {
        guard Self.isRevision(candidateCommit),
              !dependencyRevisions.isEmpty,
              dependencyRevisions.allSatisfy({
                  Self.isSafeLabel($0.key, maximum: 80) && Self.isRevision($0.value)
              }),
              Self.isSafeLabel(guildAuthorizationClass, maximum: 120),
              Self.isDigest(consentEpochHash),
              daveProtocolVersion == 1,
              selectedCodec == "H264",
              startedAt <= completedAt,
              requiredOutcomes.isSuperset(of: Self.requiredPromotionOutcomes),
              outcomes.keys.allSatisfy({
                  Self.isSafeLabel($0, maximum: 80)
              }),
              outcomes.values.allSatisfy({ $0 }),
              requiredOutcomes.allSatisfy({ outcomes[$0] == true })
        else { throw LiveMediaQualificationError.invalidQualificationReceipt }
        return self
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isRevision(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isSafeLabel(_ value: String, maximum: Int) -> Bool {
        (1...maximum).contains(value.count)
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".")
            }
    }
}

public enum LiveMediaQualificationError: Error, Equatable, Sendable {
    case canaryDisabled, managerUnauthorized, emptyParticipantSet
    case participantSetIncomplete, consentIncomplete, invalidParticipantDigest
    case invalidGuildAuthorizationClass, invalidCapabilitySet
    case noOpenEpoch, epochAlreadyOpen, epochMismatch, unsupportedDAVEVersion, unsupportedCodec
    case invalidQualificationReceipt
}

/// Process-local consent/qualification authority. It stores only participant
/// digests and aggregate counts; raw identities and media never enter receipts.
public actor LiveMediaQualificationCoordinator {
    public typealias KillSwitch = @Sendable (LiveMediaEpochCloseReason) async -> Void

    private let canaryEnabled: Bool
    private let killSwitch: KillSwitch
    private var participantDigests = Set<String>()
    private var leaseValue: DiscordVoiceQualificationLease?
    private var closeTask: Task<Void, Never>?
    private var snapshotValue: LiveMediaQualificationSnapshot

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        killSwitch: @escaping KillSwitch = { _ in }
    ) {
        let raw = (environment["ABBEY_MEDIA_QUALIFICATION_CANARY"] ?? "").lowercased()
        canaryEnabled = ["1", "true", "yes", "on"].contains(raw)
        self.killSwitch = killSwitch
        snapshotValue = .init(
            canaryEnabled: canaryEnabled,
            epoch: nil,
            lastCloseReason: nil,
            daveProtocolVersion: nil,
            codec: nil
        )
    }

    public func snapshot() -> LiveMediaQualificationSnapshot { snapshotValue }

    public func open(
        guildID: String,
        guildAuthorizationClass: String,
        participantDigests: Set<String>,
        participantSetComplete: Bool,
        allCurrentParticipantsConsented: Bool,
        managerAuthorized: Bool,
        capabilities: Set<LiveMediaCapability>,
        daveProtocolVersion: Int,
        codec: String,
        now: Date = Date()
    ) throws -> LiveMediaConsentEpoch {
        guard canaryEnabled else { throw LiveMediaQualificationError.canaryDisabled }
        guard snapshotValue.epoch == nil, closeTask == nil else {
            throw LiveMediaQualificationError.epochAlreadyOpen
        }
        guard managerAuthorized else { throw LiveMediaQualificationError.managerUnauthorized }
        guard !guildID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveMediaQualificationError.managerUnauthorized
        }
        guard Self.isSafeLabel(guildAuthorizationClass, maximum: 120) else {
            throw LiveMediaQualificationError.invalidGuildAuthorizationClass
        }
        guard participantSetComplete else {
            throw LiveMediaQualificationError.participantSetIncomplete
        }
        guard !participantDigests.isEmpty else { throw LiveMediaQualificationError.emptyParticipantSet }
        guard allCurrentParticipantsConsented else { throw LiveMediaQualificationError.consentIncomplete }
        guard !capabilities.isEmpty else { throw LiveMediaQualificationError.invalidCapabilitySet }
        guard participantDigests.allSatisfy(Self.isDigest) else {
            throw LiveMediaQualificationError.invalidParticipantDigest
        }
        guard daveProtocolVersion == 1 else {
            throw LiveMediaQualificationError.unsupportedDAVEVersion
        }
        guard codec.caseInsensitiveCompare("H264") == .orderedSame else {
            throw LiveMediaQualificationError.unsupportedCodec
        }
        let material = ([
            Self.digest(guildID),
            guildAuthorizationClass,
            String(daveProtocolVersion),
            "H264",
            ISO8601DateFormatter().string(from: now),
            UUID().uuidString,
        ] + participantDigests.sorted() + capabilities.map(\.rawValue).sorted()).joined(separator: "\u{1f}")
        let epoch = LiveMediaConsentEpoch(
            hash: Self.digest(material),
            guildIDDigest: Self.digest(guildID),
            participantSetDigest: Self.digest(participantDigests.sorted().joined(separator: "\u{1e}")),
            guildAuthorizationClass: guildAuthorizationClass,
            participantCount: participantDigests.count,
            openedAt: now,
            capabilities: capabilities
        )
        self.participantDigests = participantDigests
        snapshotValue.epoch = epoch
        snapshotValue.lastCloseReason = nil
        snapshotValue.daveProtocolVersion = daveProtocolVersion
        snapshotValue.codec = "H264"
        leaseValue = DiscordVoiceQualificationLease(
            consentEpochHash: epoch.hash,
            guildIDDigest: epoch.guildIDDigest,
            participantSetDigest: epoch.participantSetDigest,
            capabilities: epoch.capabilities,
            daveProtocolVersion: daveProtocolVersion,
            codec: "H264"
        )
        return epoch
    }

    public func qualificationLease() throws -> DiscordVoiceQualificationLease {
        guard snapshotValue.epoch != nil,
              let leaseValue
        else { throw LiveMediaQualificationError.noOpenEpoch }
        return leaseValue
    }

    public func revalidate(
        expectedEpochHash: String,
        participantDigests currentParticipants: Set<String>,
        participantSetComplete: Bool,
        managerAuthorized: Bool,
        allCurrentParticipantsConsented: Bool
    ) async throws {
        guard let epoch = snapshotValue.epoch else {
            throw LiveMediaQualificationError.noOpenEpoch
        }
        // A delayed observer from a prior epoch is stale, not evidence against
        // the replacement epoch. Reject it without closing the newer grant.
        guard epoch.hash == expectedEpochHash else {
            throw LiveMediaQualificationError.epochMismatch
        }
        if !participantSetComplete {
            await close(.participantUnidentified)
            throw LiveMediaQualificationError.participantSetIncomplete
        }
        if !managerAuthorized {
            await close(.managerAuthorizationChanged)
            throw LiveMediaQualificationError.managerUnauthorized
        }
        if !allCurrentParticipantsConsented {
            await close(.consentRevoked)
            throw LiveMediaQualificationError.consentIncomplete
        }
        if currentParticipants != participantDigests {
            await close(.participantChanged)
            throw LiveMediaQualificationError.epochMismatch
        }
    }

    public func close(_ reason: LiveMediaEpochCloseReason) async {
        if let closeTask {
            await closeTask.value
            return
        }
        leaseValue?.revoke()
        leaseValue = nil
        participantDigests.removeAll(keepingCapacity: false)
        snapshotValue.epoch = nil
        snapshotValue.lastCloseReason = reason
        snapshotValue.daveProtocolVersion = nil
        snapshotValue.codec = nil
        let killSwitch = self.killSwitch
        let task = Task { await killSwitch(reason) }
        closeTask = task
        await task.value
        closeTask = nil
    }

    public static func participantDigest(_ identity: String) -> String {
        digest(identity)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isSafeLabel(_ value: String, maximum: Int) -> Bool {
        (1...maximum).contains(value.count)
            && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".")
            }
    }
}
