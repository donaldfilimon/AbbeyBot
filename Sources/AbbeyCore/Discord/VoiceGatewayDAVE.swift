import Foundation

/// DAVE-related Discord Voice Gateway opcodes.
///
/// This type models gateway framing only. It does not implement MLS, DAVE media
/// transforms, or advertise DAVE support to Discord.
public enum VoiceGatewayDAVEOpcode: UInt8, CaseIterable, Sendable {
    case prepareTransition = 21
    case executeTransition = 22
    case transitionReady = 23
    case prepareEpoch = 24
    case externalSenderPackage = 25
    case keyPackage = 26
    case proposals = 27
    case commitWelcome = 28
    case announceCommitTransition = 29
    case welcome = 30
    case invalidCommitWelcome = 31

    public var representation: VoiceGatewayDAVEWireRepresentation {
        switch self {
        case .prepareTransition, .executeTransition, .transitionReady,
             .prepareEpoch, .invalidCommitWelcome:
            .json
        case .externalSenderPackage, .keyPackage, .proposals,
             .commitWelcome, .announceCommitTransition, .welcome:
            .binary
        }
    }

    public var direction: VoiceGatewayDAVEDirection {
        switch self {
        case .transitionReady, .keyPackage, .commitWelcome, .invalidCommitWelcome:
            .clientToServer
        case .prepareTransition, .executeTransition, .prepareEpoch,
             .externalSenderPackage, .proposals, .announceCommitTransition, .welcome:
            .serverToClient
        }
    }
}

public enum VoiceGatewayDAVEWireRepresentation: String, Equatable, Sendable {
    case json
    case binary
}

public enum VoiceGatewayDAVEDirection: String, Equatable, Sendable {
    case serverToClient
    case clientToServer
}

public enum VoiceGatewayDAVEError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyPayload
    case payloadTooLarge
    case malformedJSON
    case malformedBinary
    case truncatedBinary
    case nonCanonicalVectorLength
    case unsupportedVectorLength
    case invalidCredentialType(UInt16)
    case invalidProposalsOperation(UInt8)
    case unknownOpcode(Int)
    case wrongRepresentation(opcode: UInt8)
    case wrongDirection(opcode: UInt8)
    case invalidSequence
    case unexpectedSequence
    case invalidIdentifier
    case transitionNotPrepared(UInt16)
    case transitionMismatch(expected: UInt16, received: UInt16)
    case transitionAlreadyPending(UInt16)
    case mlsProcessingNotPending(UInt16)
    case controlHandlerUnavailable
    case controlProtocolUnavailable
    case invalidOutboundResponse(opcode: UInt8)

    public var description: String {
        switch self {
        case .emptyPayload: "DAVE payload is empty"
        case .payloadTooLarge: "DAVE payload exceeds its size limit"
        case .malformedJSON: "DAVE JSON payload is malformed"
        case .malformedBinary: "DAVE binary payload is malformed"
        case .truncatedBinary: "DAVE binary payload is truncated"
        case .nonCanonicalVectorLength: "DAVE vector length is not canonically encoded"
        case .unsupportedVectorLength: "DAVE vector length is unsupported"
        case .invalidCredentialType(let value): "DAVE external sender credential type \(value) is invalid"
        case .invalidProposalsOperation(let value): "DAVE proposals operation \(value) is invalid"
        case .unknownOpcode(let value): "DAVE opcode \(value) is unknown"
        case .wrongRepresentation(let opcode): "DAVE opcode \(opcode) used the wrong wire representation"
        case .wrongDirection(let opcode): "DAVE opcode \(opcode) used the wrong direction"
        case .invalidSequence: "DAVE server sequence number is invalid"
        case .unexpectedSequence: "DAVE client payload unexpectedly contains a server sequence number"
        case .invalidIdentifier: "DAVE session identity is invalid"
        case .transitionNotPrepared(let id): "DAVE transition \(id) was not prepared"
        case .transitionMismatch(let expected, let received):
            "DAVE transition \(received) does not match pending transition \(expected)"
        case .transitionAlreadyPending(let id): "DAVE transition \(id) is already pending"
        case .mlsProcessingNotPending(let id): "DAVE transition \(id) is not awaiting MLS processing"
        case .controlHandlerUnavailable: "DAVE control handling is unavailable"
        case .controlProtocolUnavailable: "DAVE control protocol is unavailable for this session"
        case .invalidOutboundResponse(let opcode):
            "DAVE handler produced invalid outbound opcode \(opcode)"
        }
    }
}

/// Opaque MLS or credential bytes whose textual and reflective representations
/// reveal only their length.
public struct VoiceGatewayDAVEOpaquePayload: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public static let maximumBytes = 1_048_576

    private let storage: Data

    public init(_ bytes: Data) throws {
        guard !bytes.isEmpty else { throw VoiceGatewayDAVEError.emptyPayload }
        guard bytes.count <= Self.maximumBytes else { throw VoiceGatewayDAVEError.payloadTooLarge }
        storage = bytes
    }

    public var count: Int { storage.count }

    /// Returns a copy for delivery to the native libdave boundary.
    public var bytes: Data { storage }

    public var description: String { "VoiceGatewayDAVEOpaquePayload(<redacted>, count: \(count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["bytes": "<redacted>", "count": count], displayStyle: .struct)
    }
}

public struct VoiceGatewayDAVEPrepareTransition: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let transitionID: UInt16

    public init(protocolVersion: UInt16, transitionID: UInt16) {
        self.protocolVersion = protocolVersion
        self.transitionID = transitionID
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case transitionID = "transition_id"
    }
}

public struct VoiceGatewayDAVEExecuteTransition: Codable, Equatable, Sendable {
    public let transitionID: UInt16

    public init(transitionID: UInt16) { self.transitionID = transitionID }

    enum CodingKeys: String, CodingKey { case transitionID = "transition_id" }
}

public struct VoiceGatewayDAVETransitionReady: Codable, Equatable, Sendable {
    public let transitionID: UInt16

    public init(transitionID: UInt16) { self.transitionID = transitionID }

    enum CodingKeys: String, CodingKey { case transitionID = "transition_id" }
}

public struct VoiceGatewayDAVEPrepareEpoch: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let transitionID: UInt16
    public let epoch: UInt64

    public init(protocolVersion: UInt16, transitionID: UInt16, epoch: UInt64) {
        self.protocolVersion = protocolVersion
        self.transitionID = transitionID
        self.epoch = epoch
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case transitionID = "transition_id"
        case epoch
    }
}

public struct VoiceGatewayDAVEInvalidCommitWelcome: Codable, Equatable, Sendable {
    public let transitionID: UInt16

    public init(transitionID: UInt16) { self.transitionID = transitionID }

    enum CodingKeys: String, CodingKey { case transitionID = "transition_id" }
}

public struct VoiceGatewayDAVEExternalSenderPackage: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public static let basicCredentialType: UInt16 = 1

    public let signatureKey: VoiceGatewayDAVEOpaquePayload
    public let credentialIdentity: VoiceGatewayDAVEOpaquePayload

    public init(
        signatureKey: VoiceGatewayDAVEOpaquePayload,
        credentialIdentity: VoiceGatewayDAVEOpaquePayload
    ) {
        self.signatureKey = signatureKey
        self.credentialIdentity = credentialIdentity
    }

    public var description: String {
        "VoiceGatewayDAVEExternalSenderPackage(signatureKey: <redacted \(signatureKey.count) bytes>, credentialIdentity: <redacted \(credentialIdentity.count) bytes>)"
    }
    public var debugDescription: String { description }
    /// Canonical TLS presentation used by libdave's `SetExternalSender` boundary.
    public var marshalledBytes: Data {
        var result = daveEncodeVector(signatureKey.bytes)
        result.append(UInt8(Self.basicCredentialType >> 8))
        result.append(UInt8(Self.basicCredentialType & 0xFF))
        result.append(daveEncodeVector(credentialIdentity.bytes))
        return result
    }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "signatureKey": "<redacted \(signatureKey.count) bytes>",
                "credentialIdentity": "<redacted \(credentialIdentity.count) bytes>",
            ],
            displayStyle: .struct
        )
    }
}

private func daveEncodeVector(_ bytes: Data) -> Data {
    let length = bytes.count
    if length < 64 {
        var result = Data([UInt8(length)])
        result.append(bytes)
        return result
    }
    if length < 16_384 {
        let encoded = UInt16(length) | 0x4000
        var result = Data([
            UInt8(encoded >> 8),
            UInt8(encoded & 0xFF),
        ])
        result.append(bytes)
        return result
    }
    let encoded = UInt32(length) | 0x8000_0000
    var result = Data([
        UInt8(encoded >> 24),
        UInt8((encoded >> 16) & 0xFF),
        UInt8((encoded >> 8) & 0xFF),
        UInt8(encoded & 0xFF),
    ])
    result.append(bytes)
    return result
}

public enum VoiceGatewayDAVEProposalsOperation: UInt8, Equatable, Sendable {
    case append = 0
    case revoke = 1
}

public struct VoiceGatewayDAVEProposals: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let operation: VoiceGatewayDAVEProposalsOperation
    /// For append, concatenated MLSMessage values; for revoke, ProposalRef values.
    public let vector: VoiceGatewayDAVEOpaquePayload

    public init(operation: VoiceGatewayDAVEProposalsOperation, vector: VoiceGatewayDAVEOpaquePayload) {
        self.operation = operation
        self.vector = vector
    }

    public var description: String {
        "VoiceGatewayDAVEProposals(operation: \(operation), vector: <redacted \(vector.count) bytes>)"
    }
    public var debugDescription: String { description }
    /// Canonical libdave input: revoke flag followed by one TLS vector.
    public var marshalledBytes: Data {
        var result = Data([operation.rawValue])
        result.append(daveEncodeVector(vector.bytes))
        return result
    }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["operation": operation.rawValue, "vector": "<redacted \(vector.count) bytes>"],
            displayStyle: .struct
        )
    }
}

public struct VoiceGatewayDAVEAnnounceCommitTransition: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let transitionID: UInt16
    public let commit: VoiceGatewayDAVEOpaquePayload

    public init(transitionID: UInt16, commit: VoiceGatewayDAVEOpaquePayload) {
        self.transitionID = transitionID
        self.commit = commit
    }

    public var description: String {
        "VoiceGatewayDAVEAnnounceCommitTransition(transitionID: \(transitionID), commit: <redacted \(commit.count) bytes>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["transitionID": transitionID, "commit": "<redacted \(commit.count) bytes>"],
            displayStyle: .struct
        )
    }
}

public struct VoiceGatewayDAVEWelcome: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let transitionID: UInt16
    public let welcome: VoiceGatewayDAVEOpaquePayload

    public init(transitionID: UInt16, welcome: VoiceGatewayDAVEOpaquePayload) {
        self.transitionID = transitionID
        self.welcome = welcome
    }

    public var description: String {
        "VoiceGatewayDAVEWelcome(transitionID: \(transitionID), welcome: <redacted \(welcome.count) bytes>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["transitionID": transitionID, "welcome": "<redacted \(welcome.count) bytes>"],
            displayStyle: .struct
        )
    }
}

public enum VoiceGatewayDAVEInboundMessage: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    case prepareTransition(VoiceGatewayDAVEPrepareTransition)
    case executeTransition(VoiceGatewayDAVEExecuteTransition)
    case prepareEpoch(VoiceGatewayDAVEPrepareEpoch)
    case externalSenderPackage(VoiceGatewayDAVEExternalSenderPackage)
    case proposals(VoiceGatewayDAVEProposals)
    case announceCommitTransition(VoiceGatewayDAVEAnnounceCommitTransition)
    case welcome(VoiceGatewayDAVEWelcome)

    public var opcode: VoiceGatewayDAVEOpcode {
        switch self {
        case .prepareTransition: .prepareTransition
        case .executeTransition: .executeTransition
        case .prepareEpoch: .prepareEpoch
        case .externalSenderPackage: .externalSenderPackage
        case .proposals: .proposals
        case .announceCommitTransition: .announceCommitTransition
        case .welcome: .welcome
        }
    }

    public var description: String { "VoiceGatewayDAVEInboundMessage.\(opcode)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["opcode": opcode.rawValue], displayStyle: .enum)
    }
}

public struct VoiceGatewayDAVEInboundFrame: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    /// JSON messages may omit a sequence; server binary messages always include one.
    public let sequence: UInt16?
    public let message: VoiceGatewayDAVEInboundMessage

    public init(sequence: UInt16?, message: VoiceGatewayDAVEInboundMessage) {
        self.sequence = sequence
        self.message = message
    }

    public var description: String {
        "VoiceGatewayDAVEInboundFrame(sequence: \(sequence.map(String.init) ?? "nil"), opcode: \(message.opcode.rawValue), payload: <redacted>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["sequence": sequence.map(String.init) ?? "nil", "opcode": message.opcode.rawValue, "payload": "<redacted>"],
            displayStyle: .struct
        )
    }
}

public enum VoiceGatewayDAVEClientMessage: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    case transitionReady(VoiceGatewayDAVETransitionReady)
    case keyPackage(VoiceGatewayDAVEOpaquePayload)
    /// Opaque libdave output containing an MLS commit and optional Welcome.
    case commitWelcome(VoiceGatewayDAVEOpaquePayload)
    case invalidCommitWelcome(VoiceGatewayDAVEInvalidCommitWelcome)

    public var opcode: VoiceGatewayDAVEOpcode {
        switch self {
        case .transitionReady: .transitionReady
        case .keyPackage: .keyPackage
        case .commitWelcome: .commitWelcome
        case .invalidCommitWelcome: .invalidCommitWelcome
        }
    }

    public var description: String { "VoiceGatewayDAVEClientMessage.\(opcode)(payload: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["opcode": opcode.rawValue, "payload": "<redacted>"], displayStyle: .enum)
    }
}

/// Injected boundary to the native DAVE/MLS control implementation.
///
/// AbbeyCore owns framing and transition ordering, while this handler owns the
/// cryptographic work that portable Swift cannot truthfully emulate. The default
/// remains unavailable and throws before any response is emitted.
public struct VoiceGatewayDAVEConnectionContext: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let groupID: UInt64
    public let selfUserID: UInt64

    public init(groupID: UInt64, selfUserID: UInt64) throws {
        guard groupID > 0, selfUserID > 0 else {
            throw VoiceGatewayDAVEError.invalidIdentifier
        }
        self.groupID = groupID
        self.selfUserID = selfUserID
    }

    public var description: String { "VoiceGatewayDAVEConnectionContext(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["identity": "<redacted>"], displayStyle: .struct)
    }
}

public struct VoiceGatewayDAVEControlHandler: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public typealias BeginSession = @Sendable (
        _ context: VoiceGatewayDAVEConnectionContext,
        _ protocolVersion: UInt16
    ) async throws -> [VoiceGatewayDAVEClientMessage]
    public typealias ReplaceRecognizedUserIDs = @Sendable (
        _ userIDs: [UInt64]
    ) async -> Void
    public typealias Handle = @Sendable (
        _ frame: VoiceGatewayDAVEInboundFrame,
        _ event: VoiceGatewayDAVETransitionStateMachine.Event
    ) async throws -> [VoiceGatewayDAVEClientMessage]
    public typealias Reset = @Sendable () async -> Void

    public let isAvailable: Bool
    private let beginSessionImpl: BeginSession
    private let replaceRecognizedUserIDsImpl: ReplaceRecognizedUserIDs
    private let handleImpl: Handle
    private let resetImpl: Reset

    public init(
        beginSession: @escaping BeginSession = { _, _ in [] },
        replaceRecognizedUserIDs: @escaping ReplaceRecognizedUserIDs = { _ in },
        handle: @escaping Handle,
        reset: @escaping Reset = {}
    ) {
        self.isAvailable = true
        self.beginSessionImpl = beginSession
        self.replaceRecognizedUserIDsImpl = replaceRecognizedUserIDs
        self.handleImpl = handle
        self.resetImpl = reset
    }

    private init(
        isAvailable: Bool,
        beginSession: @escaping BeginSession,
        replaceRecognizedUserIDs: @escaping ReplaceRecognizedUserIDs,
        handle: @escaping Handle,
        reset: @escaping Reset
    ) {
        self.isAvailable = isAvailable
        self.beginSessionImpl = beginSession
        self.replaceRecognizedUserIDsImpl = replaceRecognizedUserIDs
        self.handleImpl = handle
        self.resetImpl = reset
    }

    public func beginSession(
        context: VoiceGatewayDAVEConnectionContext,
        protocolVersion: UInt16
    ) async throws -> [VoiceGatewayDAVEClientMessage] {
        guard isAvailable else { throw VoiceGatewayDAVEError.controlHandlerUnavailable }
        guard protocolVersion > 0 else { throw VoiceGatewayDAVEError.controlProtocolUnavailable }
        return try await beginSessionImpl(context, protocolVersion)
    }

    public func replaceRecognizedUserIDs(_ userIDs: [UInt64]) async {
        guard isAvailable else { return }
        await replaceRecognizedUserIDsImpl(userIDs)
    }

    public func handle(
        _ frame: VoiceGatewayDAVEInboundFrame,
        event: VoiceGatewayDAVETransitionStateMachine.Event
    ) async throws -> [VoiceGatewayDAVEClientMessage] {
        guard isAvailable else { throw VoiceGatewayDAVEError.controlHandlerUnavailable }
        return try await handleImpl(frame, event)
    }

    public func reset() async {
        await resetImpl()
    }

    public var description: String {
        "VoiceGatewayDAVEControlHandler(available: \(isAvailable), implementation: <redacted>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["available": isAvailable, "implementation": "<redacted>"],
            displayStyle: .struct
        )
    }

    public static let unavailable = Self(
        isAvailable: false,
        beginSession: { _, _ in throw VoiceGatewayDAVEError.controlHandlerUnavailable },
        replaceRecognizedUserIDs: { _ in },
        handle: { _, _ in throw VoiceGatewayDAVEError.controlHandlerUnavailable },
        reset: {}
    )
}

public struct VoiceGatewayDAVEEncodedFrame: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let representation: VoiceGatewayDAVEWireRepresentation
    private let storage: Data

    fileprivate init(representation: VoiceGatewayDAVEWireRepresentation, storage: Data) {
        self.representation = representation
        self.storage = storage
    }

    public var count: Int { storage.count }
    public var bytes: Data { storage }
    public var description: String {
        "VoiceGatewayDAVEEncodedFrame(representation: \(representation.rawValue), payload: <redacted \(count) bytes>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["representation": representation.rawValue, "payload": "<redacted \(count) bytes>"],
            displayStyle: .struct
        )
    }
}

public enum VoiceGatewayDAVECodec {
    public static let maximumFrameBytes = 1_048_608

    private struct Header: Decodable {
        let op: Int
        let seq: UInt16?
    }

    private struct Envelope<Payload: Codable>: Codable {
        let op: Int
        let d: Payload
        let seq: UInt16?
    }

    public static func decodeServerJSON(_ data: Data) throws -> VoiceGatewayDAVEInboundFrame {
        try requireFrameBound(data)
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw VoiceGatewayDAVEError.malformedJSON
        }
        guard let opcode = VoiceGatewayDAVEOpcode(rawValue: UInt8(exactly: header.op) ?? 0),
              Int(opcode.rawValue) == header.op
        else { throw VoiceGatewayDAVEError.unknownOpcode(header.op) }
        guard opcode.representation == .json else {
            throw VoiceGatewayDAVEError.wrongRepresentation(opcode: opcode.rawValue)
        }
        guard opcode.direction == .serverToClient else {
            throw VoiceGatewayDAVEError.wrongDirection(opcode: opcode.rawValue)
        }

        do {
            switch opcode {
            case .prepareTransition:
                let value = try decoder.decode(Envelope<VoiceGatewayDAVEPrepareTransition>.self, from: data)
                return VoiceGatewayDAVEInboundFrame(sequence: value.seq, message: .prepareTransition(value.d))
            case .executeTransition:
                let value = try decoder.decode(Envelope<VoiceGatewayDAVEExecuteTransition>.self, from: data)
                return VoiceGatewayDAVEInboundFrame(sequence: value.seq, message: .executeTransition(value.d))
            case .prepareEpoch:
                let value = try decoder.decode(Envelope<VoiceGatewayDAVEPrepareEpoch>.self, from: data)
                return VoiceGatewayDAVEInboundFrame(sequence: value.seq, message: .prepareEpoch(value.d))
            default:
                throw VoiceGatewayDAVEError.wrongDirection(opcode: opcode.rawValue)
            }
        } catch let error as VoiceGatewayDAVEError {
            throw error
        } catch {
            throw VoiceGatewayDAVEError.malformedJSON
        }
    }

    public static func decodeServerBinary(_ data: Data) throws -> VoiceGatewayDAVEInboundFrame {
        try requireFrameBound(data)
        guard data.count >= 3 else { throw VoiceGatewayDAVEError.truncatedBinary }
        let bytes = [UInt8](data)
        let sequence = readUInt16(bytes, at: 0)
        let rawOpcode = bytes[2]
        guard let opcode = VoiceGatewayDAVEOpcode(rawValue: rawOpcode) else {
            throw VoiceGatewayDAVEError.unknownOpcode(Int(rawOpcode))
        }
        guard opcode.representation == .binary else {
            throw VoiceGatewayDAVEError.wrongRepresentation(opcode: rawOpcode)
        }
        guard opcode.direction == .serverToClient else {
            throw VoiceGatewayDAVEError.wrongDirection(opcode: rawOpcode)
        }

        var cursor = 3
        switch opcode {
        case .externalSenderPackage:
            let signatureKey = try readVector(bytes, cursor: &cursor)
            guard cursor + 2 <= bytes.count else { throw VoiceGatewayDAVEError.truncatedBinary }
            let credentialType = readUInt16(bytes, at: cursor)
            cursor += 2
            guard credentialType == VoiceGatewayDAVEExternalSenderPackage.basicCredentialType else {
                throw VoiceGatewayDAVEError.invalidCredentialType(credentialType)
            }
            let identity = try readVector(bytes, cursor: &cursor)
            guard cursor == bytes.count else { throw VoiceGatewayDAVEError.malformedBinary }
            return VoiceGatewayDAVEInboundFrame(
                sequence: sequence,
                message: .externalSenderPackage(
                    VoiceGatewayDAVEExternalSenderPackage(
                        signatureKey: try VoiceGatewayDAVEOpaquePayload(signatureKey),
                        credentialIdentity: try VoiceGatewayDAVEOpaquePayload(identity)
                    )
                )
            )
        case .proposals:
            guard cursor < bytes.count else { throw VoiceGatewayDAVEError.truncatedBinary }
            let rawOperation = bytes[cursor]
            cursor += 1
            guard let operation = VoiceGatewayDAVEProposalsOperation(rawValue: rawOperation) else {
                throw VoiceGatewayDAVEError.invalidProposalsOperation(rawOperation)
            }
            let vector = try readVector(bytes, cursor: &cursor)
            guard cursor == bytes.count else { throw VoiceGatewayDAVEError.malformedBinary }
            return VoiceGatewayDAVEInboundFrame(
                sequence: sequence,
                message: .proposals(
                    VoiceGatewayDAVEProposals(
                        operation: operation,
                        vector: try VoiceGatewayDAVEOpaquePayload(vector)
                    )
                )
            )
        case .announceCommitTransition:
            let transitionID = try readTransitionID(bytes, cursor: &cursor)
            let payload = try readRemaining(bytes, cursor: &cursor)
            return VoiceGatewayDAVEInboundFrame(
                sequence: sequence,
                message: .announceCommitTransition(
                    VoiceGatewayDAVEAnnounceCommitTransition(
                        transitionID: transitionID,
                        commit: try VoiceGatewayDAVEOpaquePayload(payload)
                    )
                )
            )
        case .welcome:
            let transitionID = try readTransitionID(bytes, cursor: &cursor)
            let payload = try readRemaining(bytes, cursor: &cursor)
            return VoiceGatewayDAVEInboundFrame(
                sequence: sequence,
                message: .welcome(
                    VoiceGatewayDAVEWelcome(
                        transitionID: transitionID,
                        welcome: try VoiceGatewayDAVEOpaquePayload(payload)
                    )
                )
            )
        default:
            throw VoiceGatewayDAVEError.wrongDirection(opcode: rawOpcode)
        }
    }

    public static func encodeClient(_ message: VoiceGatewayDAVEClientMessage) throws -> VoiceGatewayDAVEEncodedFrame {
        switch message {
        case .transitionReady(let payload):
            return try encodeJSON(opcode: .transitionReady, payload: payload)
        case .invalidCommitWelcome(let payload):
            return try encodeJSON(opcode: .invalidCommitWelcome, payload: payload)
        case .keyPackage(let payload):
            var data = Data([VoiceGatewayDAVEOpcode.keyPackage.rawValue])
            data.append(payload.bytes)
            try requireFrameBound(data)
            return VoiceGatewayDAVEEncodedFrame(representation: .binary, storage: data)
        case .commitWelcome(let payload):
            var data = Data([VoiceGatewayDAVEOpcode.commitWelcome.rawValue])
            data.append(payload.bytes)
            try requireFrameBound(data)
            return VoiceGatewayDAVEEncodedFrame(representation: .binary, storage: data)
        }
    }

    /// Strict client-frame decoding supports deterministic round-trip tests and
    /// local transport validation. Client binary frames never have a sequence prefix.
    public static func decodeClientBinary(_ data: Data) throws -> VoiceGatewayDAVEClientMessage {
        try requireFrameBound(data)
        guard let rawOpcode = data.first else { throw VoiceGatewayDAVEError.truncatedBinary }
        guard let opcode = VoiceGatewayDAVEOpcode(rawValue: rawOpcode) else {
            throw VoiceGatewayDAVEError.unknownOpcode(Int(rawOpcode))
        }
        guard opcode.representation == .binary else {
            throw VoiceGatewayDAVEError.wrongRepresentation(opcode: rawOpcode)
        }
        guard opcode.direction == .clientToServer else {
            throw VoiceGatewayDAVEError.wrongDirection(opcode: rawOpcode)
        }
        let payload = try VoiceGatewayDAVEOpaquePayload(data.dropFirstData())
        switch opcode {
        case .keyPackage: return .keyPackage(payload)
        case .commitWelcome: return .commitWelcome(payload)
        default: throw VoiceGatewayDAVEError.wrongDirection(opcode: rawOpcode)
        }
    }

    public static func decodeClientJSON(_ data: Data) throws -> VoiceGatewayDAVEClientMessage {
        try requireFrameBound(data)
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw VoiceGatewayDAVEError.malformedJSON
        }
        guard header.seq == nil else { throw VoiceGatewayDAVEError.unexpectedSequence }
        guard let rawOpcode = UInt8(exactly: header.op),
              let opcode = VoiceGatewayDAVEOpcode(rawValue: rawOpcode)
        else { throw VoiceGatewayDAVEError.unknownOpcode(header.op) }
        guard opcode.representation == .json else {
            throw VoiceGatewayDAVEError.wrongRepresentation(opcode: rawOpcode)
        }
        guard opcode.direction == .clientToServer else {
            throw VoiceGatewayDAVEError.wrongDirection(opcode: rawOpcode)
        }

        do {
            switch opcode {
            case .transitionReady:
                let value = try decoder.decode(Envelope<VoiceGatewayDAVETransitionReady>.self, from: data)
                return .transitionReady(value.d)
            case .invalidCommitWelcome:
                let value = try decoder.decode(Envelope<VoiceGatewayDAVEInvalidCommitWelcome>.self, from: data)
                return .invalidCommitWelcome(value.d)
            default:
                throw VoiceGatewayDAVEError.wrongDirection(opcode: rawOpcode)
            }
        } catch let error as VoiceGatewayDAVEError {
            throw error
        } catch {
            throw VoiceGatewayDAVEError.malformedJSON
        }
    }

    private static func encodeJSON<Payload: Codable>(
        opcode: VoiceGatewayDAVEOpcode,
        payload: Payload
    ) throws -> VoiceGatewayDAVEEncodedFrame {
        let data: Data
        do {
            data = try JSONEncoder().encode(Envelope(op: Int(opcode.rawValue), d: payload, seq: nil))
        } catch {
            throw VoiceGatewayDAVEError.malformedJSON
        }
        try requireFrameBound(data)
        return VoiceGatewayDAVEEncodedFrame(representation: .json, storage: data)
    }

    private static func requireFrameBound(_ data: Data) throws {
        guard !data.isEmpty else { throw VoiceGatewayDAVEError.emptyPayload }
        guard data.count <= maximumFrameBytes else { throw VoiceGatewayDAVEError.payloadTooLarge }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readTransitionID(_ bytes: [UInt8], cursor: inout Int) throws -> UInt16 {
        guard cursor + 2 <= bytes.count else { throw VoiceGatewayDAVEError.truncatedBinary }
        let value = readUInt16(bytes, at: cursor)
        cursor += 2
        return value
    }

    private static func readRemaining(_ bytes: [UInt8], cursor: inout Int) throws -> Data {
        guard cursor < bytes.count else { throw VoiceGatewayDAVEError.emptyPayload }
        let result = Data(bytes[cursor...])
        cursor = bytes.count
        return result
    }

    /// Decodes the 1-, 2-, or 4-byte MLS variable-size vector length header.
    private static func readVector(_ bytes: [UInt8], cursor: inout Int) throws -> Data {
        guard cursor < bytes.count else { throw VoiceGatewayDAVEError.truncatedBinary }
        let first = bytes[cursor]
        let prefix = first >> 6
        let headerBytes: Int
        switch prefix {
        case 0: headerBytes = 1
        case 1: headerBytes = 2
        case 2: headerBytes = 4
        default: throw VoiceGatewayDAVEError.unsupportedVectorLength
        }
        guard cursor + headerBytes <= bytes.count else { throw VoiceGatewayDAVEError.truncatedBinary }

        var length = Int(first & 0x3F)
        if headerBytes > 1 {
            for index in 1..<headerBytes {
                length = (length << 8) | Int(bytes[cursor + index])
            }
        }
        if (headerBytes == 2 && length < 64) || (headerBytes == 4 && length < 16_384) {
            throw VoiceGatewayDAVEError.nonCanonicalVectorLength
        }
        guard length <= VoiceGatewayDAVEOpaquePayload.maximumBytes else {
            throw VoiceGatewayDAVEError.payloadTooLarge
        }
        cursor += headerBytes
        guard cursor + length <= bytes.count else { throw VoiceGatewayDAVEError.truncatedBinary }
        let result = Data(bytes[cursor..<(cursor + length)])
        cursor += length
        return result
    }
}

public struct VoiceGatewayDAVETransitionStateMachine: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    /// Retained for source compatibility. The live session supplies its actual
    /// advertised maximum to `init(maximumProtocolVersion:)`.
    public static let advertisedProtocolVersion: UInt16 = 0

    public struct PendingEpoch: Equatable, Sendable {
        public let protocolVersion: UInt16
        public let transitionID: UInt16
        public let epoch: UInt64

        public init(protocolVersion: UInt16, transitionID: UInt16, epoch: UInt64) {
            self.protocolVersion = protocolVersion
            self.transitionID = transitionID
            self.epoch = epoch
        }
    }

    public enum Event: Equatable, Sendable {
        case transitionPrepared(UInt16)
        case transitionExecuted(UInt16)
        case epochAnnounced(PendingEpoch)
        case externalSenderRetained
        case mlsPayloadReceived(VoiceGatewayDAVEOpcode)
        case requiresMLSProcessing(UInt16)
        case transitionReady(UInt16)
        case recoveryRequired(UInt16)
    }

    public let maximumProtocolVersion: UInt16
    public private(set) var effectiveProtocolVersion: UInt16
    public private(set) var preparedTransitionID: UInt16?
    public private(set) var executedTransitionID: UInt16?
    public private(set) var awaitingMLSProcessingTransitionID: UInt16?
    public private(set) var pendingTargetProtocolVersion: UInt16?
    public private(set) var pendingEpoch: PendingEpoch?
    public private(set) var externalSenderPackage: VoiceGatewayDAVEExternalSenderPackage?

    public init(
        maximumProtocolVersion: UInt16 = .max,
        effectiveProtocolVersion: UInt16 = 0
    ) {
        self.maximumProtocolVersion = maximumProtocolVersion
        self.effectiveProtocolVersion = min(
            effectiveProtocolVersion,
            maximumProtocolVersion
        )
    }

    public mutating func initializeEffectiveProtocolVersion(_ version: UInt16) throws {
        guard version <= maximumProtocolVersion else {
            throw VoiceGatewayDAVEError.controlProtocolUnavailable
        }
        effectiveProtocolVersion = version
        clearPendingTransition()
    }

    public mutating func receive(_ message: VoiceGatewayDAVEInboundMessage) throws -> Event {
        switch message {
        case .prepareTransition(let payload):
            guard payload.protocolVersion == 0 else {
                throw VoiceGatewayDAVEError.controlProtocolUnavailable
            }
            try requireNoDifferentPendingTransition(payload.transitionID)
            awaitingMLSProcessingTransitionID = nil
            preparedTransitionID = payload.transitionID
            pendingTargetProtocolVersion = 0
            pendingEpoch = nil
            return .transitionPrepared(payload.transitionID)

        case .executeTransition(let payload):
            guard let preparedTransitionID,
                  let pendingTargetProtocolVersion
            else {
                throw VoiceGatewayDAVEError.transitionNotPrepared(payload.transitionID)
            }
            guard preparedTransitionID == payload.transitionID else {
                throw VoiceGatewayDAVEError.transitionMismatch(
                    expected: preparedTransitionID,
                    received: payload.transitionID
                )
            }
            effectiveProtocolVersion = pendingTargetProtocolVersion
            executedTransitionID = payload.transitionID
            clearPendingTransition()
            return .transitionExecuted(payload.transitionID)

        case .prepareEpoch(let payload):
            guard payload.protocolVersion > 0,
                  payload.protocolVersion <= maximumProtocolVersion
            else {
                throw VoiceGatewayDAVEError.controlProtocolUnavailable
            }
            try requireNoDifferentPendingTransition(payload.transitionID)
            let epoch = PendingEpoch(
                protocolVersion: payload.protocolVersion,
                transitionID: payload.transitionID,
                epoch: payload.epoch
            )
            preparedTransitionID = nil
            awaitingMLSProcessingTransitionID = nil
            pendingTargetProtocolVersion = payload.protocolVersion
            pendingEpoch = epoch
            return .epochAnnounced(epoch)

        case .announceCommitTransition(let payload):
            try beginMLSProcessing(payload.transitionID)
            return .requiresMLSProcessing(payload.transitionID)

        case .welcome(let payload):
            try beginMLSProcessing(payload.transitionID)
            return .requiresMLSProcessing(payload.transitionID)

        case .externalSenderPackage(let package):
            externalSenderPackage = package
            return .externalSenderRetained

        case .proposals:
            return .mlsPayloadReceived(.proposals)
        }
    }

    /// Call only after the native MLS implementation has successfully processed
    /// the commit or welcome associated with this transition.
    public mutating func markMLSProcessed(transitionID: UInt16) throws -> Event {
        guard let awaitingMLSProcessingTransitionID else {
            throw VoiceGatewayDAVEError.mlsProcessingNotPending(transitionID)
        }
        guard awaitingMLSProcessingTransitionID == transitionID else {
            throw VoiceGatewayDAVEError.transitionMismatch(
                expected: awaitingMLSProcessingTransitionID,
                received: transitionID
            )
        }
        self.awaitingMLSProcessingTransitionID = nil
        preparedTransitionID = transitionID
        if pendingTargetProtocolVersion == nil {
            pendingTargetProtocolVersion = effectiveProtocolVersion
        }
        return .transitionReady(transitionID)
    }

    /// Resets only the local MLS group after an invalid Commit or Welcome.
    /// The negotiated protocol version and trusted external-sender package remain.
    public mutating func resetMLSGroupForRecovery(transitionID: UInt16) throws -> Event {
        guard awaitingMLSProcessingTransitionID == transitionID else {
            throw VoiceGatewayDAVEError.mlsProcessingNotPending(transitionID)
        }
        clearPendingTransition()
        return .recoveryRequired(transitionID)
    }

    public func transitionReadyMessage(transitionID: UInt16) throws -> VoiceGatewayDAVEClientMessage {
        guard let preparedTransitionID else {
            throw VoiceGatewayDAVEError.transitionNotPrepared(transitionID)
        }
        guard preparedTransitionID == transitionID else {
            throw VoiceGatewayDAVEError.transitionMismatch(
                expected: preparedTransitionID,
                received: transitionID
            )
        }
        return .transitionReady(VoiceGatewayDAVETransitionReady(transitionID: transitionID))
    }

    public mutating func reset() {
        effectiveProtocolVersion = 0
        preparedTransitionID = nil
        executedTransitionID = nil
        awaitingMLSProcessingTransitionID = nil
        pendingTargetProtocolVersion = nil
        pendingEpoch = nil
        externalSenderPackage = nil
    }

    public var description: String {
        "VoiceGatewayDAVETransitionStateMachine(maximumProtocolVersion: \(maximumProtocolVersion), effectiveProtocolVersion: \(effectiveProtocolVersion), pendingTargetProtocolVersion: \(pendingTargetProtocolVersion.map(String.init) ?? "nil"), preparedTransitionID: \(preparedTransitionID.map(String.init) ?? "nil"), executedTransitionID: \(executedTransitionID.map(String.init) ?? "nil"), awaitingMLSProcessingTransitionID: \(awaitingMLSProcessingTransitionID.map(String.init) ?? "nil"), externalSenderPackage: <redacted>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        let pendingTarget = pendingTargetProtocolVersion.map(String.init) ?? "nil"
        let prepared = preparedTransitionID.map(String.init) ?? "nil"
        let executed = executedTransitionID.map(String.init) ?? "nil"
        let awaitingMLS = awaitingMLSProcessingTransitionID.map(String.init) ?? "nil"
        var children: [(label: String?, value: Any)] = []
        children.append(("maximumProtocolVersion", maximumProtocolVersion as Any))
        children.append(("effectiveProtocolVersion", effectiveProtocolVersion as Any))
        children.append(("pendingTargetProtocolVersion", pendingTarget as Any))
        children.append(("preparedTransitionID", prepared as Any))
        children.append(("executedTransitionID", executed as Any))
        children.append(("awaitingMLSProcessingTransitionID", awaitingMLS as Any))
        children.append(("externalSenderPackage", "<redacted>" as Any))
        return Mirror(self, children: children, displayStyle: .struct)
    }

    private mutating func beginMLSProcessing(_ transitionID: UInt16) throws {
        try requireNoDifferentPendingTransition(transitionID)
        preparedTransitionID = nil
        awaitingMLSProcessingTransitionID = transitionID
        if pendingTargetProtocolVersion == nil {
            pendingTargetProtocolVersion = effectiveProtocolVersion
        }
    }

    private func requireNoDifferentPendingTransition(_ transitionID: UInt16) throws {
        if let preparedTransitionID, preparedTransitionID != transitionID {
            throw VoiceGatewayDAVEError.transitionAlreadyPending(preparedTransitionID)
        }
        if let awaitingMLSProcessingTransitionID,
           awaitingMLSProcessingTransitionID != transitionID
        {
            throw VoiceGatewayDAVEError.transitionAlreadyPending(awaitingMLSProcessingTransitionID)
        }
        if let pendingEpoch, pendingEpoch.transitionID != transitionID {
            throw VoiceGatewayDAVEError.transitionAlreadyPending(pendingEpoch.transitionID)
        }
    }

    private mutating func clearPendingTransition() {
        preparedTransitionID = nil
        awaitingMLSProcessingTransitionID = nil
        pendingTargetProtocolVersion = nil
        pendingEpoch = nil
    }
}

private extension Data {
    func dropFirstData() -> Data { Data(dropFirst()) }
}
