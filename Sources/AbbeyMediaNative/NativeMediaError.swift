import Foundation

public enum NativeMediaError: Error, Sendable, Equatable {
    case initializationFailed(component: String)
    case unavailable(component: String)
    case invalidKeyLength(expected: Int, actual: Int)
    case keyMismatch
    case invalidNonceLength(expected: Int, actual: Int)
    case authenticationFailed
    case invalidFrameLength(expected: Int, actual: Int)
    case invalidPacketLength(actual: Int)
    case invalidDAVEProtocolVersion(UInt16)
    case invalidDAVEIdentifier
    case daveFrameTooLarge(actual: Int, maximum: Int)
    case daveParticipantUnavailable
    case daveCommitFailed
    case daveWelcomeFailed
    case daveMLSFailure(operation: String)
    case codecFailure(operation: String, code: Int32)
    case daveFailure(operation: String, code: UInt32)
}

extension NativeMediaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .initializationFailed(component):
            "Native component initialization failed: \(component)."
        case let .unavailable(component):
            "Native component is unavailable on this host: \(component)."
        case let .invalidKeyLength(expected, actual):
            "Invalid key length (expected \(expected) bytes, received \(actual))."
        case .keyMismatch:
            "The AEAD key does not match the initialized native context."
        case let .invalidNonceLength(expected, actual):
            "Invalid nonce length (expected \(expected) bytes, received \(actual))."
        case .authenticationFailed:
            "AEAD authentication failed."
        case let .invalidFrameLength(expected, actual):
            "Invalid PCM frame size (expected \(expected) samples, received \(actual))."
        case let .invalidPacketLength(actual):
            "Invalid Opus packet size (received \(actual) bytes)."
        case let .invalidDAVEProtocolVersion(version):
            "Unsupported DAVE protocol version \(version)."
        case .invalidDAVEIdentifier:
            "A DAVE group or participant identifier was invalid."
        case let .daveFrameTooLarge(actual, maximum):
            "DAVE media frame exceeded its bound (received \(actual) bytes, maximum \(maximum))."
        case .daveParticipantUnavailable:
            "DAVE media keys are unavailable for the requested participant."
        case .daveCommitFailed:
            "DAVE rejected the MLS commit."
        case .daveWelcomeFailed:
            "DAVE rejected the MLS welcome."
        case let .daveMLSFailure(operation):
            "DAVE rejected the MLS operation: \(operation)."
        case let .codecFailure(operation, code):
            "Opus \(operation) failed with code \(code)."
        case let .daveFailure(operation, code):
            "DAVE \(operation) failed with code \(code)."
        }
    }
}
