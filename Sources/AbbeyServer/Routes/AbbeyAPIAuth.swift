import Foundation
import Vapor

enum AbbeyAPIAuth {
    /// When `ABBEY_API_TOKEN` is set, require matching `Authorization: Bearer …` or `X-Abbey-Token`.
    /// When unset (local smoke / desktop-adjacent), gated routes stay open for loopback ops.
    /// Applied to mutating POSTs and list GET endpoints used by desktop pull sync.
    /// When the token is set, `/dashboard` SPA list tabs also need that header (or leave the token unset for open local ops).
    static func requireTokenIfConfigured(_ req: Request) throws {
        guard let expected = configuredToken else {
            return
        }
        if let bearer = req.headers.bearerAuthorization?.token,
           constantTimeEqual(bearer, expected)
        {
            return
        }
        if let header = req.headers.first(name: "X-Abbey-Token"),
           constantTimeEqual(header, expected)
        {
            return
        }
        throw Abort(.unauthorized, reason: "Valid ABBEY_API_TOKEN required (Bearer or X-Abbey-Token)")
    }

    /// Generic webhook adapters do not yet implement each provider's native signature scheme.
    /// Unlike operator routes, they therefore must not become public just because the shared
    /// token is missing. An explicit bypass is honored only by Vapor's testing environment or
    /// while ABBEY_DRY_RUN is enabled.
    static func requireConfiguredToken(
        _ req: Request,
        allowingExplicitBypass switchName: String
    ) throws {
        if allowsExplicitWebhookBypass(req, switchName: switchName) {
            req.logger.warning("Webhook authentication bypass active via \(switchName)")
            return
        }
        guard configuredToken != nil else {
            throw Abort(
                .serviceUnavailable,
                reason: "ABBEY_API_TOKEN must be configured before enabling this webhook"
            )
        }
        try requireTokenIfConfigured(req)
    }

    /// Used by provider-signed routes when missing provider credentials must fail closed.
    static func allowsExplicitWebhookBypass(_ req: Request, switchName: String) -> Bool {
        guard Environment.get(switchName) == "1" else { return false }
        if req.application.environment == .testing {
            return true
        }
        let dryRun = Environment.get("ABBEY_DRY_RUN")?.lowercased()
        return dryRun == "1" || dryRun == "true" || dryRun == "yes"
    }

    private static var configuredToken: String? {
        guard let token = Environment.get("ABBEY_API_TOKEN"),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return token
    }

    /// Avoid early-exit string comparison for bearer secrets. Length is folded into the
    /// accumulator and both byte arrays are walked to the longer length.
    private static func constantTimeEqual(_ supplied: String, _ expected: String) -> Bool {
        let lhs = Array(supplied.utf8)
        let rhs = Array(expected.utf8)
        var difference = UInt64(lhs.count ^ rhs.count)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= UInt64(left ^ right)
        }
        return difference == 0
    }
}
