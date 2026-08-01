import Foundation
import Testing
@testable import AbbeyCore

@Suite("Discord Voice portable session factory")
struct DiscordVoiceSessionFactoryTests {
    @Test("Ready constructs, opens, and discovers through one retained socket")
    func readyCreatesOneRetainedSocket() async throws {
        let recorder = FactoryUDPRecorder(
            result: .init(address: "198.51.100.42", port: 55_432)
        )
        let adapter = DiscordVoiceUDPSessionAdapter { configuration in
            recorder.record(configuration)
            return recorder
        }
        let ready = DiscordVoiceGatewayTransportReady(
            address: "203.0.113.9",
            port: 50_000,
            ssrc: 0xCAFE_BABE,
            encryptionModes: ["aead_xchacha20_poly1305_rtpsize"]
        )

        let endpoint = try await adapter.discoverEndpoint(for: ready)

        #expect(endpoint == .init(address: "198.51.100.42", port: 55_432))
        #expect(recorder.configuration()?.serverAddress == "203.0.113.9")
        #expect(recorder.configuration()?.serverPort == 50_000)
        #expect(
            await recorder.observation()
                == .init(openCount: 1, ssrcs: [0xCAFE_BABE], closeCount: 0)
        )
        #expect(await adapter.snapshot() == .init(state: .ready, retainedSocket: true))

        try await adapter.sendProtectedPacket([1, 2, 3])
        #expect(try await adapter.receiveProtectedPacket() == [4, 5, 6])
        #expect(await recorder.observation().sentPackets == [[1, 2, 3]])
        #expect(await recorder.observation().receiveCount == 1)

        await adapter.disconnect()
        #expect(await recorder.observation().closeCount == 1)
    }

    @Test("Disconnect tears down once and prevents reuse")
    func disconnectAndReuse() async throws {
        let recorder = FactoryUDPRecorder(result: .init(address: "192.0.2.4", port: 9_999))
        let adapter = DiscordVoiceUDPSessionAdapter { _ in recorder }
        let ready = validReady()

        _ = try await adapter.discoverEndpoint(for: ready)
        await adapter.disconnect()
        await adapter.disconnect()

        await expectAdapterError(.disconnected) {
            _ = try await adapter.discoverEndpoint(for: ready)
        }
        #expect(await recorder.observation().closeCount == 1)
        #expect(await adapter.snapshot() == .init(state: .disconnected, retainedSocket: false))
    }

    @Test("Repeated discovery is rejected without replacing the socket")
    func repeatedDiscoveryDoesNotReplaceSocket() async throws {
        let recorder = FactoryUDPRecorder(result: .init(address: "192.0.2.5", port: 10_000))
        let constructions = LockedCounter()
        let adapter = DiscordVoiceUDPSessionAdapter { _ in
            constructions.increment()
            return recorder
        }

        _ = try await adapter.discoverEndpoint(for: validReady())
        await expectAdapterError(.alreadyStarted) {
            _ = try await adapter.discoverEndpoint(for: validReady())
        }

        #expect(constructions.value == 1)
        await adapter.disconnect()
    }

    @Test("Invalid Ready fails before constructing a socket")
    func invalidReadyIsRejected() async {
        let constructions = LockedCounter()
        let adapter = DiscordVoiceUDPSessionAdapter { _ in
            constructions.increment()
            return FactoryUDPRecorder(result: .init(address: "192.0.2.6", port: 10_001))
        }
        let invalid = DiscordVoiceGatewayTransportReady(
            address: "  ",
            port: 0,
            ssrc: 1,
            encryptionModes: []
        )

        await expectAdapterError(.invalidReadyPayload) {
            _ = try await adapter.discoverEndpoint(for: invalid)
        }
        #expect(constructions.value == 0)
        #expect(await adapter.snapshot() == .init(state: .failed, retainedSocket: false))
    }

    @Test("Cancellation closes a discovery in progress")
    func cancellationClosesDiscovery() async throws {
        let recorder = FactoryUDPRecorder(
            result: .init(address: "192.0.2.7", port: 10_002),
            suspendDiscovery: true
        )
        let adapter = DiscordVoiceUDPSessionAdapter { _ in recorder }
        let discovery = Task { try await adapter.discoverEndpoint(for: validReady()) }
        await recorder.waitForDiscovery()

        discovery.cancel()
        await expectCancellation { _ = try await discovery.value }

        #expect(await recorder.observation().closeCount == 1)
        #expect(await adapter.snapshot() == .init(state: .disconnected, retainedSocket: false))
    }

    @Test("Factory is fail-closed and constructors are hermetic")
    func factoryAvailabilityAndInjection() {
        let gateway = FactoryGatewayClient()
        let udp = FactoryUDPDiscoveryClient()
        let gatewayConstructions = LockedCounter()
        let udpConstructions = LockedCounter()
        let factory = DiscordVoicePortableSessionFactory(
            gatewayConstructor: {
                gatewayConstructions.increment()
                return gateway
            },
            udpConstructor: {
                udpConstructions.increment()
                return udp
            }
        )

        #expect(factory.mediaAdapterAvailability == .unavailable)
        #expect(factory.makeGatewayClient() is FactoryGatewayClient)
        #expect(factory.makeUDPDiscoverySession() is FactoryUDPDiscoveryClient)
        #expect(gatewayConstructions.value == 1)
        #expect(udpConstructions.value == 1)

        let defaults = DiscordVoicePortableSessionFactory()
        #expect(defaults.mediaAdapterAvailability == .unavailable)
        #expect(defaults.makeGatewayClient() is DiscordVoiceGatewaySession)
        #expect(defaults.makeUDPDiscoverySession() is DiscordVoiceUDPSessionAdapter)
    }

    @Test("Diagnostics never reveal gateway or discovered addresses")
    func redactedDiagnostics() async throws {
        let remote = "203.0.113.199"
        let discovered = "198.51.100.211"
        let recorder = FactoryUDPRecorder(result: .init(address: discovered, port: 60_001))
        let adapter = DiscordVoiceUDPSessionAdapter { _ in recorder }
        _ = try await adapter.discoverEndpoint(
            for: .init(address: remote, port: 60_000, ssrc: 99, encryptionModes: [])
        )

        let diagnostics = [
            adapter.description,
            adapter.debugDescription,
            String(describing: await adapter.snapshot()),
            String(reflecting: adapter.customMirror)
        ].joined(separator: " ")
        #expect(!diagnostics.contains(remote))
        #expect(!diagnostics.contains(discovered))
        let errors: [DiscordVoiceUDPSessionAdapter.AdapterError] = [
            .invalidReadyPayload,
            .alreadyStarted,
            .disconnected,
            .transportFailure,
        ]
        for error in errors {
            let description = error.description
            #expect(!description.contains(remote))
            #expect(!description.contains(discovered))
        }
        await adapter.disconnect()
    }
}

private actor FactoryUDPRecorder: DiscordVoiceRetainedUDPSession {
    struct Observation: Equatable, Sendable {
        var openCount = 0
        var ssrcs: [UInt32] = []
        var closeCount = 0
        var sentPackets: [[UInt8]] = []
        var receiveCount = 0
    }

    private nonisolated let capturedConfiguration = LockedValue<DiscordVoiceUDPSession.Configuration?>(nil)
    private let result: DiscordVoiceUDPDiscoveryResult
    private let suspendDiscovery: Bool
    private var current = Observation()
    private var discoveryStarted = false
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedDiscovery: CheckedContinuation<DiscordVoiceUDPDiscoveryResult, any Error>?

    init(result: DiscordVoiceUDPDiscoveryResult, suspendDiscovery: Bool = false) {
        self.result = result
        self.suspendDiscovery = suspendDiscovery
    }

    nonisolated func record(_ configuration: DiscordVoiceUDPSession.Configuration) {
        capturedConfiguration.set(configuration)
    }

    nonisolated func configuration() -> DiscordVoiceUDPSession.Configuration? {
        capturedConfiguration.value
    }

    func open() async throws {
        current.openCount += 1
    }

    func discover(
        ssrc: UInt32,
        deadline: ContinuousClock.Instant?
    ) async throws -> DiscordVoiceUDPDiscoveryResult {
        current.ssrcs.append(ssrc)
        discoveryStarted = true
        let waiters = discoveryWaiters
        discoveryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard suspendDiscovery else { return result }
        return try await withCheckedThrowingContinuation { suspendedDiscovery = $0 }
    }

    func sendProtectedPacket(_ bytes: [UInt8]) async throws {
        current.sentPackets.append(bytes)
    }

    func receiveProtectedPacket() async throws -> [UInt8] {
        current.receiveCount += 1
        return [4, 5, 6]
    }

    func close() async {
        current.closeCount += 1
        suspendedDiscovery?.resume(throwing: CancellationError())
        suspendedDiscovery = nil
    }

    func observation() -> Observation { current }

    func waitForDiscovery() async {
        guard !discoveryStarted else { return }
        await withCheckedContinuation { discoveryWaiters.append($0) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value { lock.withLock { storage } }
    func set(_ value: Value) { lock.withLock { storage = value } }
}

private actor FactoryGatewayClient: DiscordVoiceGatewaySessionClient {
    func connect(using pair: DiscordVoiceGatewayPair) async throws -> DiscordVoiceGatewayTransportReady {
        throw CancellationError()
    }
    func selectTransport(_ endpoint: DiscordVoiceDiscoveredEndpoint) async throws {}
    func negotiateDAVEAndMedia() async throws -> DiscordVoiceMediaCapabilities {
        .init(dave: false, aead: false, opus: false)
    }
    func disconnect() async {}
}

private actor FactoryUDPDiscoveryClient: DiscordVoiceUDPDiscoverySession {
    func discoverEndpoint(
        for ready: DiscordVoiceGatewayTransportReady
    ) async throws -> DiscordVoiceDiscoveredEndpoint {
        throw CancellationError()
    }
    func disconnect() async {}
}

private func validReady() -> DiscordVoiceGatewayTransportReady {
    .init(
        address: "203.0.113.10",
        port: 50_000,
        ssrc: 7,
        encryptionModes: ["aead_xchacha20_poly1305_rtpsize"],
    )
}

private func expectAdapterError(
    _ expected: DiscordVoiceUDPSessionAdapter.AdapterError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected adapter error \(expected)")
    } catch let error as DiscordVoiceUDPSessionAdapter.AdapterError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected adapter error \(expected), received \(error)")
    }
}

private func expectCancellation(operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Expected cancellation, received \(error)")
    }
}
