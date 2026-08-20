import Foundation
#if canImport(Darwin)
import CoreFoundation
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Logging

public enum TwitchConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

/// Optional Twitch IRC + chat→ingest (Phase 2). Dry-run skips the socket; live path
/// speaks IRC over TLS to `irc.chat.twitch.tv:6697` (PASS oauth / NICK / JOIN). PRIVMSG lines
/// invoke `TwitchEventHooks`. No EventSub / PubSub.
public actor TwitchBridge {
    public private(set) var state: TwitchConnectionState = .disconnected
    public private(set) var lastError: String?
    public private(set) var loginNick: String?

    private var readTask: Task<Void, Never>?
    private var connection: TwitchIRCConnection?
    private var hooks = TwitchEventHooks()
    private var isDryRun = false
    private let logger = Logger(label: "AbbeyBot.TwitchBridge")

    /// Reconnect-with-backoff state. `reconnectParams` doubles as "should we even try to
    /// reconnect" — `disconnect()` clears it, so a stale in-flight backoff sleep becomes a
    /// no-op once it wakes (on top of the sleep itself being cancelled).
    private var reconnectParams: ConnectionParams?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private let reconnectBaseDelay: TimeInterval
    private let reconnectMaxDelay: TimeInterval
    /// ±20% jitter so many bot instances dropped by the same Twitch-side event don't all
    /// retry in lockstep.
    private static let reconnectJitterFraction = 0.2

    private struct ConnectionParams: Sendable {
        var oauthToken: String
        var login: String
        var channel: String
        var hooks: TwitchEventHooks
        var host: String
        var port: Int
        var useTLS: Bool
    }

    /// - Parameters:
    ///   - reconnectBaseDelay/reconnectMaxDelay: real-world defaults (2s / 60s); overridable so
    ///     tests can exercise the backoff loop without waiting through real-world delays.
    public init(reconnectBaseDelay: TimeInterval = 2, reconnectMaxDelay: TimeInterval = 60) {
        self.reconnectBaseDelay = reconnectBaseDelay
        self.reconnectMaxDelay = reconnectMaxDelay
    }

    /// Send a channel PRIVMSG. Dry-run logs only; no-op if disconnected.
    public func sendPrivmsg(channel: String, text: String) async {
        let chan = channel.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chan.isEmpty, !body.isEmpty else { return }
        if isDryRun {
            logger.info("dry-run: would PRIVMSG #\(chan): \(body.prefix(200))")
            return
        }
        guard let connection, state == .connected else {
            logger.warning("Twitch sendPrivmsg skipped — not connected")
            return
        }
        do {
            try await connection.send("PRIVMSG #\(chan) :\(body)")
        } catch {
            lastError = OperatorFacingError.message(error)
            logger.error("Twitch PRIVMSG send failed: \(lastError ?? "")")
        }
    }

    /// - Parameters:
    ///   - oauthToken: Twitch OAuth access token (with or without `oauth:` prefix).
    ///   - login: bot login / nick (lowercase).
    ///   - channel: channel to JOIN (without `#`).
    ///   - dryRun: when true, marks connected without opening a socket.
    ///   - hooks: PRIVMSG → engine ingest callbacks.
    public func connect(
        oauthToken: String,
        login: String,
        channel: String,
        dryRun: Bool = AppConfig.shared.dryRun,
        hooks: TwitchEventHooks = TwitchEventHooks()
    ) async {
        await connect(
            oauthToken: oauthToken,
            login: login,
            channel: channel,
            dryRun: dryRun,
            hooks: hooks,
            host: "irc.chat.twitch.tv",
            port: 6697,
            useTLS: true
        )
    }

    /// Explicit test-only transport for real-socket state-machine tests. It is internal (only
    /// reachable through `@testable import AbbeyCore`) and rejects non-loopback hosts, so a
    /// production caller cannot accidentally send a Twitch OAuth credential over cleartext.
    func connectInsecureLoopbackForTesting(
        oauthToken: String,
        login: String,
        channel: String,
        hooks: TwitchEventHooks = TwitchEventHooks(),
        host: String = "127.0.0.1",
        port: Int
    ) async {
        guard Self.isLoopback(host) else {
            state = .failed
            lastError = "Insecure Twitch IRC test transport is restricted to loopback"
            return
        }
        await connect(
            oauthToken: oauthToken,
            login: login,
            channel: channel,
            dryRun: false,
            hooks: hooks,
            host: host,
            port: port,
            useTLS: false
        )
    }

    private func connect(
        oauthToken: String,
        login: String,
        channel: String,
        dryRun: Bool,
        hooks: TwitchEventHooks,
        host: String,
        port: Int,
        useTLS: Bool
    ) async {
        self.hooks = hooks
        self.isDryRun = dryRun
        let nick = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chan = channel.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()

        if dryRun {
            await disconnect()
            isDryRun = true
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

        // Clean slate first: cancels any prior readTask/reconnectTask and clears the old
        // reconnectParams, so the params set right after aren't immediately wiped out.
        await disconnect()
        let params = ConnectionParams(
            oauthToken: oauthToken,
            login: nick,
            channel: chan,
            hooks: hooks,
            host: host,
            port: port,
            useTLS: useTLS
        )
        reconnectParams = params
        reconnectAttempt = 0
        await openConnection(params)
    }

    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectParams = nil
        readTask?.cancel()
        readTask = nil
        if let connection {
            await connection.close()
        }
        connection = nil
        state = .disconnected
        loginNick = nil
    }

    private func openConnection(_ params: ConnectionParams) async {
        self.hooks = params.hooks
        state = .connecting
        lastError = nil

        do {
            let conn = try await TwitchIRCConnection.connect(
                host: params.host,
                port: params.port,
                useTLS: params.useTLS
            )
            let pass = params.oauthToken.hasPrefix("oauth:") ? params.oauthToken : "oauth:\(params.oauthToken)"
            try await conn.send("PASS \(pass)")
            try await conn.send("NICK \(params.login)")
            try await conn.send("JOIN #\(params.channel)")
            connection = conn
            loginNick = params.login
            state = .connected
            reconnectAttempt = 0
            logger.info("Twitch IRC connected nick=\(params.login) channel=#\(params.channel)")

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
            scheduleReconnect()
        }
    }

    private func pump(_ conn: TwitchIRCConnection) async {
        while !Task.isCancelled {
            do {
                // `readLine()` returns nil on a clean peer-closed connection (normal EOF, not a
                // read error) — that must still flip state away from .connected, or sendPrivmsg
                // silently no-ops against a dead connection forever with no signal to anyone.
                guard let line = try await conn.readLine() else {
                    if !Task.isCancelled {
                        state = .failed
                        lastError = "Twitch IRC connection closed by peer"
                        logger.warning("Twitch IRC connection closed by peer")
                        scheduleReconnect()
                    }
                    break
                }
                if line.hasPrefix("PING ") || line.uppercased().hasPrefix("PING ") {
                    let payload: String
                    if let idx = line.firstIndex(of: " ") {
                        payload = String(line[line.index(after: idx)...])
                    } else {
                        payload = ""
                    }
                    try await conn.send("PONG \(payload)")
                    continue
                }
                if let msg = TwitchIRCParser.parsePrivmsg(line) {
                    await hooks.onPrivmsg(msg)
                }
            } catch {
                if !Task.isCancelled {
                    state = .failed
                    lastError = OperatorFacingError.message(error)
                    logger.error("Twitch IRC read failed: \(lastError ?? "")")
                    scheduleReconnect()
                }
                break
            }
        }
    }

    /// Schedules one reconnect attempt after an exponential-backoff-with-jitter delay. A no-op
    /// when `reconnectParams` is nil — i.e. `disconnect()` was called and we should stay down.
    private func scheduleReconnect() {
        guard let params = reconnectParams else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.attemptReconnect(after: params)
        }
    }

    private func attemptReconnect(after params: ConnectionParams) async {
        reconnectAttempt += 1
        let delay = nextReconnectDelay()
        logger.info(
            "Twitch IRC reconnecting in \(String(format: "%.1f", delay))s (attempt \(reconnectAttempt))"
        )
        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
            return // cancelled — disconnect() (or a fresh connect()) ran during the wait
        }
        guard !Task.isCancelled, reconnectParams != nil else { return }
        await openConnection(params)
    }

    private func nextReconnectDelay() -> TimeInterval {
        let capped = min(
            reconnectBaseDelay * pow(2.0, Double(reconnectAttempt - 1)),
            reconnectMaxDelay
        )
        let jitterRange = capped * Self.reconnectJitterFraction
        let jitter = Double.random(in: -jitterRange...jitterRange)
        return max(0.5, capped + jitter)
    }

    /// Also consulted by `TwitchIRCConnection.connect` as the transport-level backstop that
    /// keeps a cleartext connection from ever reaching a non-loopback host.
    static func isLoopback(_ host: String) -> Bool {
        switch host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "127.0.0.1", "::1", "localhost": return true
        default: return false
        }
    }
}

/// Minimal line-oriented Twitch IRC client. Production calls always set up certificate-
/// validated TLS before the streams are opened; plaintext exists only for the internal,
/// loopback-restricted state-machine test helper above.
actor TwitchIRCConnection {
    private let stream: any TwitchIRCByteStream
    private var buffer = Data()

    private init(stream: any TwitchIRCByteStream) {
        self.stream = stream
    }

    /// Opens a connection. Two transports, chosen by `useTLS`:
    ///
    /// * `useTLS == true` — certificate-validated TLS. Implemented on CFNetwork's stream SSL
    ///   settings (`kCFStreamSSLPeerName`, the negotiated-SSL security level), which exist only
    ///   on Apple platforms. Non-Darwin platforms therefore **fail closed** here rather than
    ///   degrading to cleartext: an unencrypted IRC connection would put the bot's OAuth token
    ///   on the wire in plaintext. Twitch IRC on Linux needs a real NIOSSL-based client, which
    ///   is separate work. Mirrors the `#if canImport(Security)` Keychain guard in AppConfig.swift.
    /// * `useTLS == false` — a plain BSD socket, reachable only from
    ///   `TwitchBridge.connectInsecureLoopbackForTesting` and restricted to loopback twice over
    ///   (the guard below, plus `TwitchLoopbackSocketStream`'s own hardcoded address table, which
    ///   never consults a resolver). It is portable, so the same lines compile and run on Darwin
    ///   and Linux and the state-machine tests work on both.
    ///
    /// Both guards run before any socket or CFNetwork call, so neither a fail-closed TLS attempt
    /// nor a rejected plaintext host touches the network.
    static func connect(host: String, port: Int, useTLS: Bool) async throws -> TwitchIRCConnection {
        // Plaintext is loopback-only on every platform. This is what makes a cleartext
        // connection to a real Twitch host unreachable by construction rather than by
        // convention, on Linux included.
        guard useTLS || TwitchBridge.isLoopback(host) else {
            throw TwitchIRCError.plaintextRestrictedToLoopback
        }

        guard useTLS else {
            return TwitchIRCConnection(
                stream: try TwitchLoopbackSocketStream.dial(host: host, port: port)
            )
        }

        #if canImport(Darwin)
        return TwitchIRCConnection(
            stream: try await TwitchCFStreamTLSStream.dial(host: host, port: port)
        )
        #else
        throw TwitchIRCError.tlsUnsupportedOnPlatform
        #endif
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
            return stream.writeBytes(base, maxLength: data.count)
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
            let n = stream.readBytes(&chunk, maxLength: chunk.count)
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
        stream.closeStream()
    }
}

/// The byte transport under `TwitchIRCConnection`'s line protocol. Exists so that only the TLS
/// implementation is Darwin-gated: the plaintext loopback implementation below is portable, so
/// the non-TLS path — and the connection-state tests that drive it — work on Linux too.
///
/// `readBytes`/`writeBytes` keep `InputStream`/`OutputStream`'s return convention: bytes moved,
/// `0` from a read means end of stream, negative means error.
protocol TwitchIRCByteStream: AnyObject {
    func writeBytes(_ bytes: UnsafePointer<UInt8>, maxLength: Int) -> Int
    func readBytes(_ bytes: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int
    func closeStream()
}

#if canImport(Darwin)
/// Certificate-validated TLS over CFNetwork's socket stream pair. Darwin-only by construction:
/// the SSL settings keys it depends on ship with CFNetwork, not with swift-corelibs-foundation.
/// TLS is applied unconditionally — this transport has no cleartext mode to fall back to.
final class TwitchCFStreamTLSStream: TwitchIRCByteStream {
    private let input: InputStream
    private let output: OutputStream

    private init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
    }

    static func dial(host: String, port: Int) async throws -> TwitchCFStreamTLSStream {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)
        guard let cfInput = readStream?.takeRetainedValue(),
              let cfOutput = writeStream?.takeRetainedValue()
        else {
            throw TwitchIRCError.streamCreateFailed
        }

        let sslSettings = [
            kCFStreamSSLPeerName as String: host,
            kCFStreamSSLValidatesCertificateChain as String: true,
        ] as CFDictionary
        let sslSettingsKey = CFStreamPropertyKey(kCFStreamPropertySSLSettings)
        let securityLevelKey = CFStreamPropertyKey(kCFStreamPropertySocketSecurityLevel)
        guard CFReadStreamSetProperty(cfInput, sslSettingsKey, sslSettings),
              CFWriteStreamSetProperty(cfOutput, sslSettingsKey, sslSettings),
              CFReadStreamSetProperty(
                  cfInput,
                  securityLevelKey,
                  kCFStreamSocketSecurityLevelNegotiatedSSL
              ),
              CFWriteStreamSetProperty(
                  cfOutput,
                  securityLevelKey,
                  kCFStreamSocketSecurityLevelNegotiatedSSL
              )
        else {
            CFReadStreamClose(cfInput)
            CFWriteStreamClose(cfOutput)
            throw TwitchIRCError.tlsConfigurationFailed
        }

        guard let input = cfInput as InputStream?,
              let output = cfOutput as OutputStream?
        else {
            CFReadStreamClose(cfInput)
            CFWriteStreamClose(cfOutput)
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
        return TwitchCFStreamTLSStream(input: input, output: output)
    }

    func writeBytes(_ bytes: UnsafePointer<UInt8>, maxLength: Int) -> Int {
        output.write(bytes, maxLength: maxLength)
    }

    func readBytes(_ bytes: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        input.read(bytes, maxLength: maxLength)
    }

    func closeStream() {
        input.close()
        output.close()
    }
}
#endif

/// Cleartext BSD-socket transport for the loopback-only test path. Deliberately built from the
/// same plain POSIX calls the connection-state tests' own listener uses, so it compiles and runs
/// identically on Darwin and Linux — the non-TLS path is therefore exercised for real on macOS
/// rather than being Linux-only code nobody can execute locally.
///
/// It resolves nothing: the address table below is hardcoded to the IPv4 loopback literal. A
/// resolver would reopen the hole the loopback restriction exists to close, since a name that
/// passes a string check can still resolve off-host.
final class TwitchLoopbackSocketStream: TwitchIRCByteStream {
    private let descriptor: Int32
    private var closed = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Named `dial` rather than `connect` so the call to the global C `connect(2)` below
    /// resolves to the syscall instead of recursing into this method.
    static func dial(host: String, port: Int) throws -> TwitchLoopbackSocketStream {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "127.0.0.1", "localhost":
            break
        default:
            // Includes "::1": this transport is IPv4-only on purpose, because an IPv6
            // loopback literal needs `in6_addr` internals whose Swift field names differ
            // between Darwin and Glibc. Rejecting is the fail-closed direction.
            throw TwitchIRCError.loopbackAddressUnsupported
        }
        guard let portNumber = UInt16(exactly: port) else {
            throw TwitchIRCError.loopbackAddressUnsupported
        }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw TwitchIRCError.loopbackSocketCreateFailed }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = portNumber.bigEndian
        // 127.0.0.1 as a literal — no `INADDR_LOOPBACK`, no resolver, no platform divergence.
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(sock)  // global C close(_:), not this type's closeStream()
            throw TwitchIRCError.loopbackConnectFailed
        }
        return TwitchLoopbackSocketStream(descriptor: sock)
    }

    func writeBytes(_ bytes: UnsafePointer<UInt8>, maxLength: Int) -> Int {
        guard !closed else { return -1 }
        return write(descriptor, bytes, maxLength)
    }

    func readBytes(_ bytes: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        guard !closed else { return 0 }
        return read(descriptor, bytes, maxLength)
    }

    func closeStream() {
        guard !closed else { return }
        closed = true
        close(descriptor)  // global C close(_:), not this method
    }
}

enum TwitchIRCError: Error, LocalizedError, Sendable {
    case streamCreateFailed
    case tlsConfigurationFailed
    case streamOpenFailed
    case encodeFailed
    case writeFailed
    case readFailed
    /// Twitch IRC over TLS is unavailable on this platform (see `TwitchIRCConnection.connect`).
    case tlsUnsupportedOnPlatform
    /// A cleartext connection was requested for a host that is not loopback. Never reachable from
    /// the production path (which always requests TLS); this is the transport-level backstop that
    /// keeps the OAuth token off the wire in cleartext on every platform.
    case plaintextRestrictedToLoopback
    case loopbackAddressUnsupported
    case loopbackSocketCreateFailed
    case loopbackConnectFailed

    var errorDescription: String? {
        switch self {
        case .tlsUnsupportedOnPlatform:
            return "Twitch IRC over TLS is not supported on this platform"
        case .plaintextRestrictedToLoopback:
            return "Cleartext Twitch IRC is restricted to loopback"
        case .loopbackAddressUnsupported:
            return "Cleartext Twitch IRC test transport supports only the IPv4 loopback address"
        case .loopbackSocketCreateFailed: return "Twitch IRC loopback socket create failed"
        case .loopbackConnectFailed: return "Twitch IRC loopback socket connect failed"
        case .streamCreateFailed: return "Twitch IRC stream create failed"
        case .tlsConfigurationFailed: return "Twitch IRC TLS configuration failed"
        case .streamOpenFailed: return "Twitch IRC stream open failed"
        case .encodeFailed: return "Twitch IRC encode failed"
        case .writeFailed: return "Twitch IRC write failed"
        case .readFailed: return "Twitch IRC read failed"
        }
    }
}
