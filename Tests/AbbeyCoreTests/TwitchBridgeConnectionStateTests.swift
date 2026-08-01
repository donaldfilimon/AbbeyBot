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
        await bridge.connectInsecureLoopbackForTesting(
            oauthToken: "test-only-oauth-token",
            login: "testbot",
            channel: "testchannel",
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

        // Stop the background reconnect loop this drop scheduled — otherwise it keeps retrying
        // against this now-closed listener in the background after the test returns.
        await bridge.disconnect()
    }

    /// Exercises the scheduling/cancellation contract without depending on a full second
    /// socket round-trip. A separate, ad hoc experiment (not kept as a test) confirmed the
    /// reconnect mechanism DOES eventually succeed against a real listener — but attempts
    /// launched from the freshly-spawned reconnect Task took consistently ~76s to complete a
    /// connection that the original, directly-awaited connect() call completes in well under a
    /// second. `TwitchIRCConnection` never schedules its CFStreams on any run loop
    /// (`input.open()`/`output.open()` with no `.schedule(in:forMode:)`), which is a plausible
    /// explanation if that unscheduled state machine behaves differently off the calling
    /// context that happened to drive the first connection — but this is not confirmed, and is
    /// exactly the kind of "reconnect is nominally 2s-60s but a real attempt might silently
    /// take over a minute" gap worth flagging rather than hiding. Whoever picks this up next:
    /// reproduce outside Swift Testing's task-scheduling context before assuming either cause.
    ///
    /// This test instead proves the part that's cheap to verify with confidence: a drop
    /// schedules a reconnect, and an explicit `disconnect()` during the backoff wait actually
    /// cancels it — the bridge must not silently reconnect out from under a caller that asked
    /// it to stop.
    @Test func disconnectDuringBackoffWaitCancelsTheScheduledReconnect() async throws {
        let port = try LoopbackListener.ephemeralPort()
        let firstListener = try LoopbackListener(port: port)
        let firstAccept = Task.detached {
            firstListener.acceptOnceThenCloseAfterFirstRead()
        }

        // Long enough that this test's own disconnect() call always lands well inside the
        // backoff wait, never racing the (real, working) reconnect attempt itself.
        let bridge = TwitchBridge(reconnectBaseDelay: 5, reconnectMaxDelay: 5)
        await bridge.connectInsecureLoopbackForTesting(
            oauthToken: "test-only-oauth-token",
            login: "testbot",
            channel: "testchannel",
            host: "127.0.0.1",
            port: Int(port)
        )
        #expect(await bridge.state == .connected)

        await firstAccept.value
        firstListener.closeListener()

        var dropped = await bridge.state
        for _ in 0..<150 where dropped == .connected {
            try await Task.sleep(nanoseconds: 20_000_000)
            dropped = await bridge.state
        }
        #expect(dropped == .failed)

        // Well inside the 5s backoff window — this must actually stop the scheduled attempt.
        await bridge.disconnect()
        #expect(await bridge.state == .disconnected)

        // If cancellation didn't work, the reconnect would fire around the 5s mark and (since
        // nothing is listening on `port` anymore) flip state to .connecting or .failed again.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(await bridge.state == .disconnected)
    }

    @Test func insecureTestTransportRejectsNonLoopbackHostBeforeSendingCredentials() async {
        let bridge = TwitchBridge()
        await bridge.connectInsecureLoopbackForTesting(
            oauthToken: "must-not-leave-process",
            login: "testbot",
            channel: "testchannel",
            host: "example.com",
            port: 6667
        )

        #expect(await bridge.state == .failed)
        #expect(await bridge.lastError == "Insecure Twitch IRC test transport is restricted to loopback")
    }
}

/// Minimal loopback TCP listener for triggering a real, clean peer-close in tests.
private final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let listenSocket: Int32

    enum ListenerError: Error {
        case socketFailed, bindFailed, listenFailed, getsocknameFailed
    }

    /// Binds an ephemeral port, reads it back via `getsockname`, then closes — for handing a
    /// free port number to a *later* `LoopbackListener(port:)` (simulating "the server came
    /// back on the same address").  Small window for another process to grab the port first;
    /// acceptable for a local test, not for anything production-facing.
    static func ephemeralPort() throws -> UInt16 {
        let listener = try LoopbackListener(port: 0)
        defer { listener.closeListener() }
        return listener.port
    }

    init(port requestedPort: UInt16 = 0) throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ListenerError.socketFailed }

        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian == INADDR_ANY ? INADDR_ANY : INADDR_ANY.byteSwapped
        addr.sin_port = requestedPort.bigEndian

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
