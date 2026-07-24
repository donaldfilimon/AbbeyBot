import Foundation

/// Single policy for operator-facing error text (Discord copy, desktop UI, CLI, sync).
public enum OperatorFacingError: Sendable {
    public static func message(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
