import Foundation
import Logging

public enum TwitchConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

/// Optional Twitch IRC presence (Phase 2). Dry-run skips the socket; live path speaks
/// IRC to `irc.chat.twitch.tv:6667` (PASS oauth / NICK / JOIN). No EventSub, no pubsub.
public actor TwitchBridge {
    public private(set) var state: TwitchConnectionState = .disconnected
    public private(set) var lastError: String?
    public private(set) var loginNick: String?

    private var readTask: Task<Void, Never>?
    private var connection: TwitchIRCConnection?
    private let logger = Logger(label: "AbbeyBot.TwitchBridge")

    public init() {}

    /// - Parameters:
    ///   - oauthToken: Twitch OAuth access token (with or without `oauth:` prefix).
    ///   - login: bot login / nick (lowercase).
    ///   - channel: channel to JOIN (without `#`).
    ///   - dryRun: when true, marks connected without opening a socket.
    public func connect(
        oauthToken: String,
        login: String,
        channel: String,
        dryRun: Bool = AppConfig.shared.dryRun
    ) async {
        let nick = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chan = channel.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()

        if dryRun {
            await disconnect()
            state = .connected
            lastError = nil
            loginNick = nick.isEmpty ? "dry-run" : nick
            logger.info("dry-run: would connect Twitch IRC nick=\(loginNick ?? "") channel=#\(chan); socket skipped")
            return
        }

        guard !oauthToken.isEmpty else {
            state = .failed
            lastError = "TWITCH_OAUTH_TOKEN is empty"
            return
        }
        guard !nick.isEmpty else {
            state = .failed
            lastError = "TWITCH_BOT_LOGIN is empty"
            return
        }
        guard !chan.isEmpty else {
            state = .failed
            lastError = "TWITCH_CHANNEL is empty"
            return
        }

        await disconnect()
        state = .connecting
        lastError = nil

        do {
            let conn = try await TwitchIRCConnection.connect(
                host: "irc.chat.twitch.tv",
                port: 6667
            )
            let pass = oauthToken.hasPrefix("oauth:") ? oauthToken : "oauth:\(oauthToken)"
            try await conn.send("PASS \(pass)")
            try await conn.send("NICK \(nick)")
            try await conn.send("JOIN #\(chan)")
            connection = conn
            loginNick = nick
            state = .connected
            logger.info("Twitch IRC connected nick=\(nick) channel=#\(chan)")

            readTask = Task { [weak self] in
                guard let self else { return }
                await self.pump(conn)
            }
        } catch {
            state = .failed
            lastError = OperatorFacingError.message(error)
            connection = nil
            loginNick = nil
            logger.error("Twitch IRC connect failed: \(lastError ?? "")")
        }
    }

    public func disconnect() async {
        readTask?.cancel()
        readTask = nil
        if let connection {
            await connection.close()
        }
        connection = nil
        state = .disconnected
        loginNick = nil
    }

    private func pump(_ conn: TwitchIRCConnection) async {
        while !Task.isCancelled {
            do {
                guard let line = try await conn.readLine() else { break }
                if line.hasPrefix("PING ") {
                    let payload = String(line.dropFirst(5))
                    try await conn.send("PONG \(payload)")
                }
            } catch {
                if !Task.isCancelled {
                    state = .failed
                    lastError = OperatorFacingError.message(error)
                    logger.error("Twitch IRC read failed: \(lastError ?? "")")
                }
                break
            }
        }
    }
}

/// Minimal line-oriented TCP client for Twitch IRC (no TLS — Twitch allows 6667 cleartext).
actor TwitchIRCConnection {
    private let input: InputStream
    private let output: OutputStream
    private var buffer = Data()

    private init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
    }

    static func connect(host: String, port: Int) async throws -> TwitchIRCConnection {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)
        guard let input = readStream?.takeRetainedValue() as InputStream?,
              let output = writeStream?.takeRetainedValue() as OutputStream?
        else {
            throw TwitchIRCError.streamCreateFailed
        }
        input.open()
        output.open()
        // Brief wait for open
        try await Task.sleep(nanoseconds: 200_000_000)
        if input.streamStatus == .error || output.streamStatus == .error {
            input.close()
            output.close()
            throw TwitchIRCError.streamOpenFailed
        }
        return TwitchIRCConnection(input: input, output: output)
    }

    func send(_ line: String) throws {
        var payload = line
        if !payload.hasSuffix("\r\n") {
            payload += "\r\n"
        }
        guard let data = payload.data(using: .utf8) else {
            throw TwitchIRCError.encodeFailed
        }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return output.write(base, maxLength: data.count)
        }
        if written < 0 {
            throw TwitchIRCError.writeFailed
        }
    }

    func readLine() async throws -> String? {
        while true {
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = input.read(&chunk, maxLength: chunk.count)
            if n < 0 {
                throw TwitchIRCError.readFailed
            }
            if n == 0 {
                if buffer.isEmpty { return nil }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                return line
            }
            buffer.append(contentsOf: chunk.prefix(n))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func close() {
        input.close()
        output.close()
    }
}

enum TwitchIRCError: Error, LocalizedError, Sendable {
    case streamCreateFailed
    case streamOpenFailed
    case encodeFailed
    case writeFailed
    case readFailed

    var errorDescription: String? {
        switch self {
        case .streamCreateFailed: return "Twitch IRC stream create failed"
        case .streamOpenFailed: return "Twitch IRC stream open failed"
        case .encodeFailed: return "Twitch IRC encode failed"
        case .writeFailed: return "Twitch IRC write failed"
        case .readFailed: return "Twitch IRC read failed"
        }
    }
}
