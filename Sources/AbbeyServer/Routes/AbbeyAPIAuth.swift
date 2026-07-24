import Vapor

enum AbbeyAPIAuth {
    /// When `ABBEY_API_TOKEN` is set, require matching `Authorization: Bearer …` or `X-Abbey-Token`.
    /// When unset (local smoke / desktop-adjacent), mutating routes stay open on loopback ops.
    static func requireTokenIfConfigured(_ req: Request) throws {
        guard let expected = Environment.get("ABBEY_API_TOKEN"), !expected.isEmpty else {
            return
        }
        if let bearer = req.headers.bearerAuthorization?.token, bearer == expected {
            return
        }
        if let header = req.headers.first(name: "X-Abbey-Token"), header == expected {
            return
        }
        throw Abort(.unauthorized, reason: "Valid ABBEY_API_TOKEN required (Bearer or X-Abbey-Token)")
    }
}
