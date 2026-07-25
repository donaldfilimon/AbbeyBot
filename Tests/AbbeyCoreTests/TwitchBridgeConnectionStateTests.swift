import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@testable import AbbeyCore

/// Real-socket tests for `TwitchBridge`'s connection-state tracking. Uses a local raw-BSD-socket
/// listener (same lower-level style `TwitchIRCConnection` itself uses) rather than mocking
/// `TwitchIRCConnection` — the bug under test lives in how `pump()` reacts to an actual socket
/// closing, which a mock can't reproduce faithfully.
@Suite("TwitchBridge connection state")
struct TwitchBridgeConnectionStateTests {
    @Test func pumpTransitionsAwayFromConnectedOnCleanEOF() async throws {
        let listener = try LoopbackListener()
        defer { listener.closeListener() }

        let acceptTask = Task.detached {
            listener.acceptOnceThenCloseAfterFirstRead()
        }

        let bridge = TwitchBridge()
        await bridge.connect(
            oauthToken: "fake-oauth-token",
            login: "testbot",
            channel: "testchannel",
            dryRun: false,
            host: "127.0.0.1",
            port: Int(listener.port)
        )

        #expect(await bridge.state == .connected)

        await acceptTask.value

        // pump() reacts to the close asynchronously on its own Task — poll with a timeout
        // rather than a fixed sleep, since exactly how fast the FIN propagates isn't deterministic.
        var observed = await bridge.state
        for _ in 0..<150 where observed == .connected {
            try await Task.sleep(nanoseconds: 20_000_000)
            observed = await bridge.state
        }

        #expect(observed != .connected)
        #expect(await bridge.lastError != nil)
    }
}

/// Minimal loopback TCP listener for triggering a real, clean peer-close in tests.
private final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let listenSocket: Int32

    enum ListenerError: Error {
        case socketFailed, bindFailed, listenFailed, getsocknameFailed
    }

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ListenerError.socketFailed }

        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian == INADDR_ANY ? INADDR_ANY : INADDR_ANY.byteSwapped
        addr.sin_port = 0 // ask the kernel for an ephemeral port

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(sock)
            throw ListenerError.bindFailed
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsocknameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(sock, sockaddrPtr, &len)
            }
        }
        guard getsocknameResult == 0 else {
            close(sock)
            throw ListenerError.getsocknameFailed
        }
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        guard listen(sock, 1) == 0 else {
            close(sock)
            throw ListenerError.listenFailed
        }
        self.listenSocket = sock
    }

    /// Blocks (on whatever thread calls this — call from a detached Task) until one client
    /// connects, reads whatever it sends (PASS/NICK/JOIN), then closes cleanly.
    func acceptOnceThenCloseAfterFirstRead() {
        let client = accept(listenSocket, nil, nil)
        guard client >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = read(client, &buffer, buffer.count)
        close(client)
    }

    func closeListener() {
        close(listenSocket)  // global C close(_:), safe here (renamed wrapper)
    }
}
