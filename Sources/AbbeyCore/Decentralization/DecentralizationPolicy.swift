import Foundation

/// Decentralization / blockchain policy stub. Always off in this package — no
/// nodes, wallets, or consensus. Enabling without an implementation fails validation.
public struct DecentralizationPolicy: Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public static let disabled = DecentralizationPolicy(enabled: false)

    public enum ValidationError: Error, LocalizedError, Sendable {
        case blockchainNotImplemented

        public var errorDescription: String? {
            "DecentralizationPolicy.enabled is true, but no blockchain/node implementation ships in AbbeyBot. Keep enabled=false (see AGENTS.md)."
        }
    }

    public func validate() throws {
        if enabled {
            throw ValidationError.blockchainNotImplemented
        }
    }
}
