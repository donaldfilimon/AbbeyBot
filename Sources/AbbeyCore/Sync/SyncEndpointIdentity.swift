import Foundation

/// Stable, secret-free identity for namespacing sync progress by remote endpoint.
public enum SyncEndpointIdentity: Sendable {
    public static func normalized(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? trimmed
    }

    /// FNV-1a is used only as a compact deterministic filename/defaults-key suffix, not
    /// for authentication or secrecy.
    public static func storageKey(for endpoint: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized(endpoint).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
