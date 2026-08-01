import Foundation
import NIOCore

/// The fixed-width UDP packet used by Discord voice IP discovery.
public enum DiscordVoiceUDPDiscoveryCodec {
    public static let packetSize = 74

    /// Encodes Discord's 74-byte IP discovery request.
    public static func encodeRequest(ssrc: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: packetSize)
        write(UInt16(1), into: &bytes, at: 0)
        write(UInt16(70), into: &bytes, at: 2)
        write(ssrc, into: &bytes, at: 4)
        return bytes
    }

    /// Decodes and strictly validates Discord's 74-byte IP discovery response.
    public static func decodeResponse(
        _ bytes: [UInt8],
        expectedSSRC: UInt32
    ) throws -> DiscordVoiceUDPDiscoveryResult {
        guard bytes.count == packetSize else {
            throw DiscordVoiceUDPDiscoveryError.invalidPacketSize
        }
        guard readUInt16(bytes, at: 0) == 2 else {
            throw DiscordVoiceUDPDiscoveryError.invalidType
        }
        guard readUInt16(bytes, at: 2) == 70 else {
            throw DiscordVoiceUDPDiscoveryError.invalidLength
        }
        guard readUInt32(bytes, at: 4) == expectedSSRC else {
            throw DiscordVoiceUDPDiscoveryError.ssrcMismatch
        }

        let addressField = bytes[8..<72]
        guard let terminator = addressField.firstIndex(of: 0) else {
            throw DiscordVoiceUDPDiscoveryError.missingAddressTerminator
        }
        guard addressField[addressField.index(after: terminator)...].allSatisfy({ $0 == 0 }) else {
            throw DiscordVoiceUDPDiscoveryError.nonZeroAddressPadding
        }

        let addressBytes = addressField[..<terminator]
        guard let address = String(bytes: addressBytes, encoding: .utf8) else {
            throw DiscordVoiceUDPDiscoveryError.invalidAddressEncoding
        }
        guard (try? SocketAddress(ipAddress: address, port: 1)) != nil else {
            throw DiscordVoiceUDPDiscoveryError.invalidAddress
        }

        let port = readUInt16(bytes, at: 72)
        guard port != 0 else {
            throw DiscordVoiceUDPDiscoveryError.invalidPort
        }
        return DiscordVoiceUDPDiscoveryResult(address: address, port: port)
    }

    private static func readUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24)
            | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8)
            | UInt32(bytes[index + 3])
    }

    private static func write(_ value: UInt16, into bytes: inout [UInt8], at index: Int) {
        bytes[index] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[index + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func write(_ value: UInt32, into bytes: inout [UInt8], at index: Int) {
        bytes[index] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[index + 3] = UInt8(truncatingIfNeeded: value)
    }
}

public struct DiscordVoiceUDPDiscoveryResult: Equatable, Sendable {
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

/// Deliberately contains no associated payloads, addresses, or packet bytes.
public enum DiscordVoiceUDPDiscoveryError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPacketSize
    case invalidType
    case invalidLength
    case ssrcMismatch
    case missingAddressTerminator
    case invalidAddressEncoding
    case invalidAddress
    case nonZeroAddressPadding
    case invalidPort
    case invalidConfiguration
    case datagramLimitExceeded
    case responseStreamEnded
    case timeout
    case transportFailure

    public var description: String {
        switch self {
        case .invalidPacketSize: "Discord voice IP discovery packet had an invalid size"
        case .invalidType: "Discord voice IP discovery packet had an invalid type"
        case .invalidLength: "Discord voice IP discovery packet had an invalid length"
        case .ssrcMismatch: "Discord voice IP discovery packet did not match the session"
        case .missingAddressTerminator: "Discord voice IP discovery address was not terminated"
        case .invalidAddressEncoding: "Discord voice IP discovery address encoding was invalid"
        case .invalidAddress: "Discord voice IP discovery address was invalid"
        case .nonZeroAddressPadding: "Discord voice IP discovery address padding was invalid"
        case .invalidPort: "Discord voice IP discovery port was invalid"
        case .invalidConfiguration: "Discord voice IP discovery configuration was invalid"
        case .datagramLimitExceeded: "Discord voice IP discovery received too many datagrams"
        case .responseStreamEnded: "Discord voice IP discovery response stream ended"
        case .timeout: "Discord voice IP discovery timed out"
        case .transportFailure: "Discord voice IP discovery transport failed"
        }
    }
}
