import Foundation

/// Parses Twitch IRC lines for chat ingest. Pure — no I/O.
public enum TwitchIRCParser: Sendable {
    public struct Privmsg: Sendable, Equatable {
        public var channel: String
        public var login: String
        public var text: String

        public init(channel: String, login: String, text: String) {
            self.channel = channel
            self.login = login
            self.text = text
        }
    }

    /// Example: `:user!user@user.tmi.twitch.tv PRIVMSG #chan :hello there`
    /// Optional IRCv3 tags prefix `@key=value;… ` is stripped.
    public static func parsePrivmsg(_ line: String) -> Privmsg? {
        var rest = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }

        if rest.hasPrefix("@") {
            guard let sp = rest.firstIndex(of: " ") else { return nil }
            rest = String(rest[rest.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        }

        var prefix = ""
        if rest.hasPrefix(":") {
            guard let sp = rest.firstIndex(of: " ") else { return nil }
            prefix = String(rest[rest.index(after: rest.startIndex)..<sp])
            rest = String(rest[rest.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        }

        let upper = rest.uppercased()
        guard upper.hasPrefix("PRIVMSG ") else { return nil }
        rest = String(rest.dropFirst(8))

        guard let colonIdx = rest.firstIndex(of: ":") else { return nil }
        var channel = String(rest[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let text = String(rest[rest.index(after: colonIdx)...])
        if channel.hasPrefix("#") {
            channel.removeFirst()
        }
        channel = channel.lowercased()

        var login = ""
        if let bang = prefix.firstIndex(of: "!") {
            login = String(prefix[..<bang]).lowercased()
        } else if !prefix.isEmpty {
            login = prefix.lowercased()
        }

        guard !channel.isEmpty, !login.isEmpty else { return nil }
        return Privmsg(channel: channel, login: login, text: text)
    }
}

/// Callbacks for Twitch IRC events (chat → engine ingest).
public struct TwitchEventHooks: Sendable {
    public var onPrivmsg: @Sendable (TwitchIRCParser.Privmsg) async -> Void

    public init(onPrivmsg: @escaping @Sendable (TwitchIRCParser.Privmsg) async -> Void = { _ in }) {
        self.onPrivmsg = onPrivmsg
    }
}
