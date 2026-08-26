import Foundation

public enum QuasarServePolicyError: Error, LocalizedError, Equatable, Sendable {
    case missingOptionValue(String)
    case duplicateAddressOption(String)
    case incompatibleAddressOptions
    case unixSocketUnsupported
    case invalidHostname(String)
    case invalidPort(String)
    case nonLoopbackPolicyIncomplete

    public var errorDescription: String? {
        switch self {
        case .missingOptionValue(let option):
            return "Quasar serve option \(option) requires a value."
        case .duplicateAddressOption(let option):
            return "Quasar serve option \(option) was supplied more than once."
        case .incompatibleAddressOptions:
            return "Quasar serve --bind cannot be combined with hostname or port options."
        case .unixSocketUnsupported:
            return "Quasar serve does not accept --unix-socket; use the governed hostname and port options."
        case .invalidHostname(let value):
            return "Quasar serve hostname is invalid: \(value)"
        case .invalidPort(let value):
            return "Quasar serve port is invalid: \(value)"
        case .nonLoopbackPolicyIncomplete:
            return "Non-loopback Quasar requires ABBEY_QUASAR_ALLOW_NON_LOOPBACK=1, ABBEY_QUASAR_API_TOKEN, and exact HTTPS ABBEY_QUASAR_ALLOWED_ORIGINS."
        }
    }
}

public struct QuasarServeConfiguration: Equatable, Sendable {
    public var hostname: String
    public var port: Int
    public var vaporArguments: [String]
    public var allowedOrigins: Set<String>
    public var allowsTokenlessLoopback: Bool
}

/// One parser governs every Vapor address spelling before the arguments reach
/// ConsoleKit. It consumes long, equals, short, attached-short, and `--bind`
/// forms, then emits one canonical hostname/port pair. No later alias can
/// override the host that was subjected to the non-loopback policy.
public enum QuasarServePolicy {
    public static func prepare(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> QuasarServeConfiguration {
        var hostnameValue: String?
        var portValue: String?
        var bindValue: String?
        var passthrough: [String] = []
        var index = 0

        func assign(_ value: String, to destination: inout String?, option: String) throws {
            guard destination == nil else {
                throw QuasarServePolicyError.duplicateAddressOption(option)
            }
            guard !value.isEmpty else {
                throw QuasarServePolicyError.missingOptionValue(option)
            }
            destination = value
        }

        func followingValue(for option: String) throws -> String {
            let candidateIndex = index + 1
            guard arguments.indices.contains(candidateIndex),
                  !arguments[candidateIndex].isEmpty,
                  !arguments[candidateIndex].hasPrefix("-")
            else { throw QuasarServePolicyError.missingOptionValue(option) }
            index = candidateIndex
            return arguments[candidateIndex]
        }

        while arguments.indices.contains(index) {
            let argument = arguments[index]
            switch argument {
            case "--hostname", "-H":
                try assign(
                    followingValue(for: argument),
                    to: &hostnameValue,
                    option: "--hostname"
                )
            case "--port", "-p":
                try assign(
                    followingValue(for: argument),
                    to: &portValue,
                    option: "--port"
                )
            case "--bind", "-b":
                try assign(
                    followingValue(for: argument),
                    to: &bindValue,
                    option: "--bind"
                )
            case "--unix-socket":
                throw QuasarServePolicyError.unixSocketUnsupported
            default:
                if let value = longValue(argument, option: "--hostname") {
                    try assign(value, to: &hostnameValue, option: "--hostname")
                } else if let value = longValue(argument, option: "--port") {
                    try assign(value, to: &portValue, option: "--port")
                } else if let value = longValue(argument, option: "--bind") {
                    try assign(value, to: &bindValue, option: "--bind")
                } else if argument.hasPrefix("--unix-socket=") {
                    throw QuasarServePolicyError.unixSocketUnsupported
                } else if let value = attachedShortValue(argument, option: "-H") {
                    try assign(value, to: &hostnameValue, option: "--hostname")
                } else if let value = attachedShortValue(argument, option: "-p") {
                    try assign(value, to: &portValue, option: "--port")
                } else if let value = attachedShortValue(argument, option: "-b") {
                    try assign(value, to: &bindValue, option: "--bind")
                } else {
                    passthrough.append(argument)
                }
            }
            index += 1
        }

        if bindValue != nil, hostnameValue != nil || portValue != nil {
            throw QuasarServePolicyError.incompatibleAddressOptions
        }

        let configuredHostname = environment["ABBEY_QUASAR_BIND"] ?? "127.0.0.1"
        let configuredPort = environment["ABBEY_QUASAR_PORT"] ?? "4700"
        let finalHostname: String
        let finalPort: Int
        if let bindValue {
            (finalHostname, finalPort) = try parseBind(bindValue)
        } else {
            finalHostname = try normalizedHostname(hostnameValue ?? configuredHostname)
            finalPort = try parsedPort(portValue ?? configuredPort)
        }

        let origins = Set((environment["ABBEY_QUASAR_ALLOWED_ORIGINS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        if !isLoopback(finalHostname) {
            let token = environment["ABBEY_QUASAR_API_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard environment["ABBEY_QUASAR_ALLOW_NON_LOOPBACK"] == "1",
                  !token.isEmpty,
                  token.utf8.count <= 4_096,
                  !origins.isEmpty,
                  origins.allSatisfy(isValidExactHTTPSOrigin)
            else { throw QuasarServePolicyError.nonLoopbackPolicyIncomplete }
        }

        return QuasarServeConfiguration(
            hostname: finalHostname,
            port: finalPort,
            vaporArguments: passthrough + [
                "--hostname", finalHostname,
                "--port", String(finalPort),
            ],
            allowedOrigins: origins.filter(isValidExactHTTPSOrigin),
            allowsTokenlessLoopback: isLoopback(finalHostname)
        )
    }

    public static func isValidExactHTTPSOrigin(_ value: String) -> Bool {
        isValidOrigin(value, permitsLoopbackHTTP: false)
    }

    static func isValidBrowserOrigin(
        _ value: String,
        configuredRemoteOrigins: Set<String>
    ) -> Bool {
        guard let components = validOriginComponents(value) else { return false }
        let host = components.host?.lowercased() ?? ""
        if isLoopback(host) {
            return components.scheme?.lowercased() == "http"
                || components.scheme?.lowercased() == "https"
        }
        return components.scheme?.lowercased() == "https"
            && configuredRemoteOrigins.contains(value)
            && isValidExactHTTPSOrigin(value)
    }

    private static func longValue(_ argument: String, option: String) -> String? {
        let prefix = option + "="
        guard argument.hasPrefix(prefix) else { return nil }
        return String(argument.dropFirst(prefix.count))
    }

    private static func attachedShortValue(_ argument: String, option: String) -> String? {
        guard argument.hasPrefix(option), argument.count > option.count else { return nil }
        let suffix = argument.dropFirst(option.count)
        return String(suffix.first == "=" ? suffix.dropFirst() : suffix)
    }

    private static func parseBind(_ raw: String) throws -> (String, Int) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let port: String
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"),
                  value.index(after: close) < value.endIndex,
                  value[value.index(after: close)] == ":"
            else { throw QuasarServePolicyError.invalidHostname(raw) }
            host = String(value[value.index(after: value.startIndex)..<close])
            port = String(value[value.index(close, offsetBy: 2)...])
        } else {
            guard let separator = value.lastIndex(of: ":"),
                  separator != value.startIndex,
                  value.index(after: separator) < value.endIndex
            else { throw QuasarServePolicyError.invalidHostname(raw) }
            host = String(value[..<separator])
            port = String(value[value.index(after: separator)...])
        }
        return (try normalizedHostname(host), try parsedPort(port))
    }

    private static func normalizedHostname(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        guard !value.isEmpty,
              value.utf8.count <= 253,
              !value.hasPrefix("-"),
              !value.hasSuffix("-"),
              !value.contains("*"),
              value.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":")
              })
        else { throw QuasarServePolicyError.invalidHostname(raw) }
        return value
    }

    private static func parsedPort(_ raw: String) throws -> Int {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(value), (1...65_535).contains(port) else {
            throw QuasarServePolicyError.invalidPort(raw)
        }
        return port
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
    }

    private static func isValidOrigin(
        _ value: String,
        permitsLoopbackHTTP: Bool
    ) -> Bool {
        guard let components = validOriginComponents(value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else { return false }
        if scheme == "https" { return true }
        return permitsLoopbackHTTP && scheme == "http" && isLoopback(host)
    }

    private static func validOriginComponents(_ value: String) -> URLComponents? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("*"),
              let components = URLComponents(string: value),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.host?.isEmpty == false,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65_535).contains($0) }) ?? true
        else { return nil }
        return components
    }
}
