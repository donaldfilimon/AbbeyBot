import Foundation

/// Validation failures at the Discord Voice Gateway boundary.
public enum VoiceGatewayV8Error: Error, Equatable, Sendable, CustomStringConvertible {
    case endpointTooLong
    case malformedEndpoint
    case nonSecureWebSocketScheme
    case endpointContainsUserInfo
    case endpointContainsFragment
    case endpointContainsUnexpectedPath
    case endpointContainsUnexpectedQuery
    case invalidHost
    case invalidPort
    case emptyField(String)
    case fieldTooLong(String)
    case invalidHeartbeatInterval
    case invalidSequence
    case invalidReadyPayload
    case invalidEncryptionMode
    case invalidSecretKeyLength
    case unsupportedDAVEVersion(Int)
    case payloadTooLarge
    case unsupportedOpcode(Int)
    case malformedPayload
    case unexpectedEvent
    case heartbeatAcknowledgementMismatch
    case missedHeartbeatAcknowledgement
    case resumeUnavailable

    public var description: String {
        switch self {
        case .endpointTooLong: "Voice endpoint exceeds its size limit"
        case .malformedEndpoint: "Voice endpoint is malformed"
        case .nonSecureWebSocketScheme: "Voice endpoint must use wss"
        case .endpointContainsUserInfo: "Voice endpoint must not contain user information"
        case .endpointContainsFragment: "Voice endpoint must not contain a fragment"
        case .endpointContainsUnexpectedPath: "Voice endpoint contains an unexpected path"
        case .endpointContainsUnexpectedQuery: "Voice endpoint contains an unexpected query"
        case .invalidHost: "Voice endpoint host is invalid"
        case .invalidPort: "Voice endpoint port is invalid"
        case .emptyField(let field): "Voice payload field \(field) is empty"
        case .fieldTooLong(let field): "Voice payload field \(field) exceeds its size limit"
        case .invalidHeartbeatInterval: "Voice heartbeat interval is invalid"
        case .invalidSequence: "Voice Gateway sequence is invalid"
        case .invalidReadyPayload: "Voice Ready payload is invalid"
        case .invalidEncryptionMode: "Voice encryption mode is invalid"
        case .invalidSecretKeyLength: "Voice secret key must contain exactly 32 bytes"
        case .unsupportedDAVEVersion(let version): "DAVE protocol version \(version) is not supported"
        case .payloadTooLarge: "Voice Gateway payload exceeds its size limit"
        case .unsupportedOpcode(let opcode): "Voice Gateway opcode \(opcode) is not supported"
        case .malformedPayload: "Voice Gateway payload is malformed"
        case .unexpectedEvent: "Voice Gateway event is not valid in the current phase"
        case .heartbeatAcknowledgementMismatch: "Voice heartbeat acknowledgement does not match the pending heartbeat"
        case .missedHeartbeatAcknowledgement: "Voice heartbeat acknowledgement deadline expired"
        case .resumeUnavailable: "Voice Gateway session cannot be resumed"
        }
    }
}

/// A normalized ephemeral Voice Gateway endpoint.
///
/// Discord sends a host (and sometimes a `wss` URL) in Voice Server Update. Only
/// secure WebSocket endpoints are accepted. The URL is normalized to Gateway v8.
public struct VoiceGatewayV8Endpoint: Equatable, Sendable, CustomStringConvertible {
    public static let maximumInputBytes = 2_048

    public let url: URL

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceGatewayV8Error.malformedEndpoint }
        guard trimmed.utf8.count <= Self.maximumInputBytes else { throw VoiceGatewayV8Error.endpointTooLong }

        let hasScheme = trimmed.contains("://")
        let candidate = hasScheme ? trimmed : "wss://\(trimmed)"
        guard var components = URLComponents(string: candidate) else {
            throw VoiceGatewayV8Error.malformedEndpoint
        }
        guard components.scheme?.lowercased() == "wss" else {
            throw VoiceGatewayV8Error.nonSecureWebSocketScheme
        }
        guard components.user == nil, components.password == nil else {
            throw VoiceGatewayV8Error.endpointContainsUserInfo
        }
        guard components.fragment == nil else {
            throw VoiceGatewayV8Error.endpointContainsFragment
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw VoiceGatewayV8Error.endpointContainsUnexpectedPath
        }
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            guard queryItems.count == 1,
                  queryItems[0].name == "v",
                  queryItems[0].value == "8"
            else {
                throw VoiceGatewayV8Error.endpointContainsUnexpectedQuery
            }
        }
        guard let host = components.host, Self.isValidHost(host) else {
            throw VoiceGatewayV8Error.invalidHost
        }
        if candidate.contains(":"), components.port == nil,
           let authority = candidate.split(separator: "/", maxSplits: 3).last,
           authority.last == ":" {
            throw VoiceGatewayV8Error.invalidPort
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw VoiceGatewayV8Error.invalidPort
        }

        components.scheme = "wss"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "v", value: "8")]
        guard let normalized = components.url else { throw VoiceGatewayV8Error.malformedEndpoint }
        self.url = normalized
    }

    public var description: String { url.absoluteString }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        guard !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            return false
        }
        // URLComponents has already parsed bracketed IPv6 literals.
        if host.contains(":") { return true }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-"
            else { return false }
            return label.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }
        }
    }
}

enum VoiceGatewayV8Bounds {
    static let identifier = 128
    static let sessionID = 512
    static let token = 4_096
    static let address = 255
    static let mode = 128
    static let maximumModes = 32
    static let maximumDAVEProtocolVersion = Int(UInt16.max)

    static func require(_ value: String, field: String, maximum: Int) throws {
        guard !value.isEmpty else { throw VoiceGatewayV8Error.emptyField(field) }
        guard value.utf8.count <= maximum else { throw VoiceGatewayV8Error.fieldTooLong(field) }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VoiceGatewayV8Error.malformedPayload
        }
    }
}

public struct VoiceGatewayV8Identify: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public static let opcode = 0
    public let serverID: String
    public let userID: String
    public let sessionID: String
    public let token: String
    /// Highest DAVE protocol version the active media runtime can complete.
    /// Portable callers default to zero and therefore remain fail-closed.
    public let maxDAVEProtocolVersion: Int
    /// Whether this connection supports video (documented Identify field,
    /// default false when omitted). Signaling advertisement only — no video
    /// media path exists in this repository.
    public let video: Bool?
    /// Proposed simulcast streams to send. The voice server assigns the real
    /// SSRCs in Ready. Omitted entirely when nil, preserving the historical
    /// audio-only wire shape.
    public let streams: [VoiceGatewayV8Stream]?

    public init(
        serverID: String,
        userID: String,
        sessionID: String,
        token: String,
        maxDAVEProtocolVersion: Int = 0,
        video: Bool? = nil,
        streams: [VoiceGatewayV8Stream]? = nil
    ) throws {
        try VoiceGatewayV8Bounds.require(serverID, field: "server_id", maximum: VoiceGatewayV8Bounds.identifier)
        try VoiceGatewayV8Bounds.require(userID, field: "user_id", maximum: VoiceGatewayV8Bounds.identifier)
        try VoiceGatewayV8Bounds.require(sessionID, field: "session_id", maximum: VoiceGatewayV8Bounds.sessionID)
        try VoiceGatewayV8Bounds.require(token, field: "token", maximum: VoiceGatewayV8Bounds.token)
        guard (0...VoiceGatewayV8Bounds.maximumDAVEProtocolVersion).contains(maxDAVEProtocolVersion) else {
            throw VoiceGatewayV8Error.unsupportedDAVEVersion(maxDAVEProtocolVersion)
        }
        if let streams {
            guard video == true else { throw VoiceGatewayV8Error.malformedPayload }
            try VoiceGatewayV8VideoValidation.validateIdentifyStreams(streams)
        }
        self.serverID = serverID
        self.userID = userID
        self.sessionID = sessionID
        self.token = token
        self.maxDAVEProtocolVersion = maxDAVEProtocolVersion
        self.video = video
        self.streams = try streams.map { try $0.map { try $0.validated() } }
    }

    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case userID = "user_id"
        case sessionID = "session_id"
        case token
        case maxDAVEProtocolVersion = "max_dave_protocol_version"
        case video
        case streams
    }

    public var description: String {
        "VoiceGatewayV8Identify(serverID: \(serverID), userID: \(userID), sessionID: <redacted>, token: <redacted>, maxDAVEProtocolVersion: \(maxDAVEProtocolVersion))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: [
            "serverID": serverID,
            "userID": userID,
            "sessionID": "<redacted>",
            "token": "<redacted>",
            "maxDAVEProtocolVersion": maxDAVEProtocolVersion,
        ], displayStyle: .struct)
    }
}

public struct VoiceGatewayV8Hello: Codable, Equatable, Sendable {
    public static let opcode = 8
    public let heartbeatInterval: UInt64

    public init(heartbeatInterval: UInt64) throws {
        guard (100...300_000).contains(heartbeatInterval) else {
            throw VoiceGatewayV8Error.invalidHeartbeatInterval
        }
        self.heartbeatInterval = heartbeatInterval
    }

    enum CodingKeys: String, CodingKey { case heartbeatInterval = "heartbeat_interval" }

    fileprivate func validated() throws -> Self { try Self(heartbeatInterval: heartbeatInterval) }
}

public struct VoiceGatewayV8Heartbeat: Codable, Equatable, Sendable {
    public static let opcode = 3
    public let t: UInt64
    public let sequenceAcknowledgement: Int?

    public init(t: UInt64, sequenceAcknowledgement: Int?) throws {
        if let sequenceAcknowledgement, sequenceAcknowledgement < 0 {
            throw VoiceGatewayV8Error.invalidSequence
        }
        self.t = t
        self.sequenceAcknowledgement = sequenceAcknowledgement
    }

    enum CodingKeys: String, CodingKey { case t; case sequenceAcknowledgement = "seq_ack" }
}

public struct VoiceGatewayV8HeartbeatACK: Codable, Equatable, Sendable {
    public static let opcode = 6
    public let t: UInt64

    public init(t: UInt64) { self.t = t }
}

public struct VoiceGatewayV8Ready: Codable, Equatable, Sendable {
    public static let opcode = 2
    public let ssrc: UInt32
    public let ip: String
    public let port: UInt16
    public let modes: [String]
    /// Populated simulcast streams: the server-assigned local send SSRCs for
    /// the streams offered in Identify. Absent on audio-only connections.
    public let streams: [VoiceGatewayV8Stream]?

    public init(
        ssrc: UInt32,
        ip: String,
        port: UInt16,
        modes: [String],
        streams: [VoiceGatewayV8Stream]? = nil
    ) throws {
        try VoiceGatewayV8Bounds.require(ip, field: "ip", maximum: VoiceGatewayV8Bounds.address)
        guard port > 0, !modes.isEmpty, modes.count <= VoiceGatewayV8Bounds.maximumModes else {
            throw VoiceGatewayV8Error.invalidReadyPayload
        }
        for mode in modes {
            try VoiceGatewayV8Bounds.require(mode, field: "mode", maximum: VoiceGatewayV8Bounds.mode)
        }
        let validatedStreams = try streams.map { try $0.map { try $0.validated() } }
        if let validatedStreams {
            try VoiceGatewayV8VideoValidation.validateNegotiatedStreams(
                validatedStreams,
                audioSSRC: ssrc,
                requireType: true,
                failure: .invalidReadyPayload
            )
        } else if ssrc == 0 {
            throw VoiceGatewayV8Error.invalidReadyPayload
        }
        self.ssrc = ssrc
        self.ip = ip
        self.port = port
        self.modes = modes
        self.streams = validatedStreams
    }

    fileprivate func validated() throws -> Self {
        try Self(ssrc: ssrc, ip: ip, port: port, modes: modes, streams: streams)
    }
}

public struct VoiceGatewayV8SelectProtocol: Codable, Equatable, Sendable {
    public static let opcode = 1
    public let protocolName: String
    public let data: DataPayload

    public struct DataPayload: Codable, Equatable, Sendable {
        public let address: String
        public let port: UInt16
        public let mode: String
    }

    public init(address: String, port: UInt16, mode: String) throws {
        try VoiceGatewayV8Bounds.require(address, field: "address", maximum: VoiceGatewayV8Bounds.address)
        try VoiceGatewayV8Bounds.require(mode, field: "mode", maximum: VoiceGatewayV8Bounds.mode)
        guard port > 0 else { throw VoiceGatewayV8Error.invalidPort }
        self.protocolName = "udp"
        self.data = DataPayload(address: address, port: port, mode: mode)
    }

    enum CodingKeys: String, CodingKey { case protocolName = "protocol"; case data }
}

public struct VoiceGatewayV8SessionDescription: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public static let opcode = 4
    public let mode: String
    public let secretKey: [UInt8]
    public let daveProtocolVersion: Int

    public init(mode: String, secretKey: [UInt8], daveProtocolVersion: Int) throws {
        try VoiceGatewayV8Bounds.require(mode, field: "mode", maximum: VoiceGatewayV8Bounds.mode)
        guard secretKey.count == 32 else { throw VoiceGatewayV8Error.invalidSecretKeyLength }
        guard (0...VoiceGatewayV8Bounds.maximumDAVEProtocolVersion).contains(daveProtocolVersion) else {
            throw VoiceGatewayV8Error.unsupportedDAVEVersion(daveProtocolVersion)
        }
        self.mode = mode
        self.secretKey = secretKey
        self.daveProtocolVersion = daveProtocolVersion
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case secretKey = "secret_key"
        case daveProtocolVersion = "dave_protocol_version"
    }

    fileprivate func validated() throws -> Self {
        try Self(mode: mode, secretKey: secretKey, daveProtocolVersion: daveProtocolVersion)
    }

    public var description: String {
        "VoiceGatewayV8SessionDescription(mode: \(mode), secretKey: <redacted>, daveProtocolVersion: \(daveProtocolVersion))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: [
            "mode": mode,
            "secretKey": "<redacted>",
            "daveProtocolVersion": daveProtocolVersion,
        ], displayStyle: .struct)
    }
}

public struct VoiceGatewayV8Speaking: Codable, Equatable, Sendable {
    public static let opcode = 5
    public let speaking: Int
    public let delay: Int
    public let ssrc: UInt32
    public let userID: String?

    public init(speaking: Int, delay: Int = 0, ssrc: UInt32, userID: String? = nil) throws {
        guard speaking >= 0, speaking <= 7, delay >= 0, delay <= 60_000 else {
            throw VoiceGatewayV8Error.malformedPayload
        }
        if let userID {
            try VoiceGatewayV8Bounds.require(
                userID,
                field: "user_id",
                maximum: VoiceGatewayV8Bounds.identifier
            )
        }
        self.speaking = speaking
        self.delay = delay
        self.ssrc = ssrc
        self.userID = userID
    }

    enum CodingKeys: String, CodingKey {
        case speaking, delay, ssrc
        case userID = "user_id"
    }

    fileprivate func validated() throws -> Self {
        try Self(speaking: speaking, delay: delay, ssrc: ssrc, userID: userID)
    }
}

public struct VoiceGatewayV8ClientsConnect: Codable, Equatable, Sendable {
    public static let opcode = 11
    public let userIDs: [String]

    public init(userIDs: [String]) throws {
        guard userIDs.count <= 10_000 else { throw VoiceGatewayV8Error.malformedPayload }
        for userID in userIDs {
            try VoiceGatewayV8Bounds.require(
                userID,
                field: "user_id",
                maximum: VoiceGatewayV8Bounds.identifier
            )
        }
        self.userIDs = userIDs
    }

    enum CodingKeys: String, CodingKey { case userIDs = "user_ids" }

    fileprivate func validated() throws -> Self { try Self(userIDs: userIDs) }
}

public struct VoiceGatewayV8ClientDisconnect: Codable, Equatable, Sendable {
    public static let opcode = 13
    public let userID: String

    public init(userID: String) throws {
        try VoiceGatewayV8Bounds.require(
            userID,
            field: "user_id",
            maximum: VoiceGatewayV8Bounds.identifier
        )
        self.userID = userID
    }

    enum CodingKeys: String, CodingKey { case userID = "user_id" }

    fileprivate func validated() throws -> Self { try Self(userID: userID) }
}

public struct VoiceGatewayV8Resume: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public static let opcode = 7
    public let serverID: String
    public let sessionID: String
    public let token: String
    public let sequenceAcknowledgement: Int

    public init(serverID: String, sessionID: String, token: String, sequenceAcknowledgement: Int) throws {
        try VoiceGatewayV8Bounds.require(serverID, field: "server_id", maximum: VoiceGatewayV8Bounds.identifier)
        try VoiceGatewayV8Bounds.require(sessionID, field: "session_id", maximum: VoiceGatewayV8Bounds.sessionID)
        try VoiceGatewayV8Bounds.require(token, field: "token", maximum: VoiceGatewayV8Bounds.token)
        guard sequenceAcknowledgement >= 0 else { throw VoiceGatewayV8Error.invalidSequence }
        self.serverID = serverID
        self.sessionID = sessionID
        self.token = token
        self.sequenceAcknowledgement = sequenceAcknowledgement
    }

    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case sessionID = "session_id"
        case token
        case sequenceAcknowledgement = "seq_ack"
    }

    public var description: String {
        "VoiceGatewayV8Resume(serverID: \(serverID), sessionID: <redacted>, token: <redacted>, seqAck: \(sequenceAcknowledgement))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: [
            "serverID": serverID,
            "sessionID": "<redacted>",
            "token": "<redacted>",
            "sequenceAcknowledgement": sequenceAcknowledgement,
        ], displayStyle: .struct)
    }
}

public struct VoiceGatewayV8Resumed: Codable, Equatable, Sendable {
    public static let opcode = 9
    public init() {}
}

public enum VoiceGatewayV8Outbound: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case identify(VoiceGatewayV8Identify)
    case selectProtocol(VoiceGatewayV8SelectProtocol)
    case heartbeat(VoiceGatewayV8Heartbeat)
    case speaking(VoiceGatewayV8Speaking)
    case resume(VoiceGatewayV8Resume)
    /// Video state announcement. Sent by the native media plane's
    /// announcement-before-send obligation ahead of outbound video packets;
    /// no capture, encoder, or receive path exists behind it.
    case video(VoiceGatewayV8Video)
    /// Desired remote media stream quality (signaling only).
    case mediaSinkWants(VoiceGatewayV8MediaSinkWants)

    enum CodingKeys: String, CodingKey { case op, d }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .identify(let payload):
            try container.encode(VoiceGatewayV8Identify.opcode, forKey: .op)
            try container.encode(payload, forKey: .d)
        case .selectProtocol(let payload):
            try container.encode(VoiceGatewayV8SelectProtocol.opcode, forKey: .op)
            try container.encode(payload, forKey: .d)
        case .heartbeat(let payload):
            try container.encode(VoiceGatewayV8Heartbeat.opcode, forKey: .op)
            try container.encode(payload, forKey: .d)
        case .speaking(let payload):
            try container.encode(VoiceGatewayV8Speaking.opcode, forKey: .op)
            try container.encode(payload, forKey: .d)
        case .resume(let payload):
            try container.encode(VoiceGatewayV8Resume.opcode, forKey: .op)
            try container.encode(payload, forKey: .d)
        case .video(let payload):
            try payload.validateForOutboundEncoding()
            try container.encode(VoiceGatewayV8Video.opcode, forKey: .op)
            try container.encode(payload, forKey: .d)
        case .mediaSinkWants(let payload):
            try container.encode(VoiceGatewayV8MediaSinkWants.opcode, forKey: .op)
            try container.encode(payload, forKey: .d)
        }
    }

    public var description: String {
        switch self {
        case .identify(let value): "VoiceGatewayV8Outbound.identify(\(value))"
        case .selectProtocol(let value): "VoiceGatewayV8Outbound.selectProtocol(\(value))"
        case .heartbeat(let value): "VoiceGatewayV8Outbound.heartbeat(\(value))"
        case .speaking(let value): "VoiceGatewayV8Outbound.speaking(\(value))"
        case .resume(let value): "VoiceGatewayV8Outbound.resume(\(value))"
        case .video(let value): "VoiceGatewayV8Outbound.video(\(value))"
        case .mediaSinkWants(let value): "VoiceGatewayV8Outbound.mediaSinkWants(\(value))"
        }
    }
    public var debugDescription: String { description }
}

private extension VoiceGatewayV8Video {
    /// Opcode 12 is direction-asymmetric. Discord's inbound event adds
    /// `user_id` and may omit the top-level RTX SSRC, while AbbeyBot's outbound
    /// announcement must never impersonate a server event and must identify the
    /// exact primary/RTX pair it will send. Keep this validation at the encoder
    /// boundary so valid inbound fixtures remain decodable.
    func validateForOutboundEncoding() throws {
        guard userID == nil else { throw VoiceGatewayV8Error.malformedPayload }

        if streams.isEmpty {
            guard videoSSRC == 0, rtxSSRC == 0 else {
                throw VoiceGatewayV8Error.malformedPayload
            }
            return
        }

        guard videoSSRC != 0,
              let outboundRTXSSRC = rtxSSRC,
              outboundRTXSSRC != 0,
              let selected = streams.first(where: { $0.ssrc == videoSSRC }),
              selected.derivedRTXSSRC == outboundRTXSSRC
        else { throw VoiceGatewayV8Error.malformedPayload }
    }
}

public struct VoiceGatewayV8Inbound: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Payload: Sendable {
        case hello(VoiceGatewayV8Hello)
        case heartbeatACK(VoiceGatewayV8HeartbeatACK)
        case ready(VoiceGatewayV8Ready)
        case sessionDescription(VoiceGatewayV8SessionDescription)
        case speaking(VoiceGatewayV8Speaking)
        case resumed(VoiceGatewayV8Resumed)
        case clientsConnect(VoiceGatewayV8ClientsConnect)
        case clientDisconnect(VoiceGatewayV8ClientDisconnect)
        /// A user's video state was announced (signaling only).
        case video(VoiceGatewayV8Video)
        /// Requested media stream quality updated (signaling only).
        case mediaSinkWants(VoiceGatewayV8MediaSinkWants)
    }

    public let sequence: Int?
    public let payload: Payload

    public var description: String {
        let name = switch payload {
        case .hello: "hello"
        case .heartbeatACK: "heartbeatACK"
        case .ready: "ready"
        case .sessionDescription: "sessionDescription(<redacted>)"
        case .speaking: "speaking"
        case .resumed: "resumed"
        case .clientsConnect: "clientsConnect"
        case .clientDisconnect: "clientDisconnect"
        case .video: "video"
        case .mediaSinkWants: "mediaSinkWants"
        }
        return "VoiceGatewayV8Inbound(sequence: \(sequence.map(String.init) ?? "nil"), payload: \(name))"
    }
    public var debugDescription: String { description }
}

public enum VoiceGatewayV8Decoder {
    public static let maximumPayloadBytes = 65_536

    private struct Envelope<Payload: Decodable>: Decodable {
        let op: Int
        let d: Payload
        let seq: Int?
    }

    public static func decode(_ data: Data) throws -> VoiceGatewayV8Inbound {
        guard data.count <= maximumPayloadBytes else { throw VoiceGatewayV8Error.payloadTooLarge }
        struct Header: Decodable { let op: Int; let seq: Int? }
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw VoiceGatewayV8Error.malformedPayload
        }
        if let sequence = header.seq, sequence < 0 { throw VoiceGatewayV8Error.invalidSequence }

        do {
            switch header.op {
            case VoiceGatewayV8Hello.opcode:
                let envelope = try decoder.decode(Envelope<VoiceGatewayV8Hello>.self, from: data)
                return VoiceGatewayV8Inbound(sequence: envelope.seq, payload: .hello(try envelope.d.validated()))
            case VoiceGatewayV8HeartbeatACK.opcode:
                let envelope = try decoder.decode(Envelope<VoiceGatewayV8HeartbeatACK>.self, from: data)
                return VoiceGatewayV8Inbound(sequence: envelope.seq, payload: .heartbeatACK(envelope.d))
            case VoiceGatewayV8Ready.opcode:
                let envelope = try decoder.decode(Envelope<VoiceGatewayV8Ready>.self, from: data)
                return VoiceGatewayV8Inbound(sequence: envelope.seq, payload: .ready(try envelope.d.validated()))
            case VoiceGatewayV8SessionDescription.opcode:
                let envelope = try decoder.decode(Envelope<VoiceGatewayV8SessionDescription>.self, from: data)
                return VoiceGatewayV8Inbound(sequence: envelope.seq, payload: .sessionDescription(try envelope.d.validated()))
            case VoiceGatewayV8Speaking.opcode:
                let envelope = try decoder.decode(Envelope<VoiceGatewayV8Speaking>.self, from: data)
                return VoiceGatewayV8Inbound(sequence: envelope.seq, payload: .speaking(try envelope.d.validated()))
            case VoiceGatewayV8Resumed.opcode:
                return VoiceGatewayV8Inbound(sequence: header.seq, payload: .resumed(VoiceGatewayV8Resumed()))
            case VoiceGatewayV8ClientsConnect.opcode:
                let envelope = try decoder.decode(Envelope<VoiceGatewayV8ClientsConnect>.self, from: data)
                return VoiceGatewayV8Inbound(sequence: envelope.seq, payload: .clientsConnect(try envelope.d.validated()))
            case VoiceGatewayV8ClientDisconnect.opcode:
                let envelope = try decoder.decode(Envelope<VoiceGatewayV8ClientDisconnect>.self, from: data)
                return VoiceGatewayV8Inbound(sequence: envelope.seq, payload: .clientDisconnect(try envelope.d.validated()))
            case VoiceGatewayV8Video.opcode:
                let envelope = try decoder.decode(Envelope<VoiceGatewayV8Video>.self, from: data)
                return VoiceGatewayV8Inbound(sequence: envelope.seq, payload: .video(try envelope.d.validated()))
            case VoiceGatewayV8MediaSinkWants.opcode:
                let envelope = try decoder.decode(Envelope<VoiceGatewayV8MediaSinkWants>.self, from: data)
                return VoiceGatewayV8Inbound(sequence: envelope.seq, payload: .mediaSinkWants(try envelope.d.validated()))
            default:
                throw VoiceGatewayV8Error.unsupportedOpcode(header.op)
            }
        } catch let error as VoiceGatewayV8Error {
            throw error
        } catch {
            throw VoiceGatewayV8Error.malformedPayload
        }
    }
}
