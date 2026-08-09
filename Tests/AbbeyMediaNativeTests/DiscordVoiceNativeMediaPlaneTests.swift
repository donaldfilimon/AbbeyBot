import AbbeyCore
import Testing
@testable import AbbeyMediaNative

@Suite("Native Discord negotiated media plane")
struct DiscordVoiceNativeMediaPlaneTests {
    @Test("protocol zero installs AEAD and Opus without claiming DAVE")
    func protocolZeroBootstrap() async throws {
        let plane = makePlane(daveSession: nil)
        let capability = try makeCapability(generation: 1, daveProtocolVersion: 0)

        let capabilities = try await plane.install(capability)

        #expect(capabilities.dave == false)
        #expect(capabilities.aead)
        #expect(capabilities.opus)
        #expect(await plane.snapshot().isInstalled)
        #expect(await plane.hasInstalledSource(0x1111_1111))

        let rendered = "\(plane) \(String(reflecting: plane)) \(await plane.snapshot())"
        #expect(rendered.contains("<redacted>"))
        #expect(!rendered.contains("286331153"))
        #expect(!rendered.contains("a7a7"))

        await plane.reset()
        #expect(await plane.snapshot().isInstalled == false)
    }

    @Test("generation watermark rejects duplicates and stale installs across reset")
    func generationWatermark() async throws {
        let plane = makePlane(daveSession: nil)
        _ = try await plane.install(makeCapability(generation: 2, daveProtocolVersion: 0))

        await #expect(throws: DiscordVoiceNegotiatedMediaError.duplicateInstallation) {
            _ = try await plane.install(
                makeCapability(generation: 2, daveProtocolVersion: 0)
            )
        }
        await #expect(throws: DiscordVoiceNegotiatedMediaError.staleInstallation) {
            _ = try await plane.install(
                makeCapability(generation: 1, daveProtocolVersion: 0)
            )
        }

        _ = try await plane.install(makeCapability(generation: 3, daveProtocolVersion: 0))
        #expect(await plane.snapshot().isInstalled)
        await plane.reset()

        await #expect(throws: DiscordVoiceNegotiatedMediaError.duplicateInstallation) {
            _ = try await plane.install(
                makeCapability(generation: 3, daveProtocolVersion: 0)
            )
        }
        #expect(await plane.snapshot().isInstalled == false)
    }

    @Test("nonzero DAVE requires the matching media-ready native session")
    func nonzeroDAVERequiresReadySession() async throws {
        let readySession = NativeDAVEMediaSessionDouble(
            protocolVersion: 1,
            isMediaReady: true
        )
        let readyPlane = makePlane(daveSession: readySession)
        let capabilities = try await readyPlane.install(
            makeCapability(generation: 4, daveProtocolVersion: 1)
        )
        #expect(capabilities.dave)
        #expect(capabilities.aead)
        #expect(capabilities.opus)

        let wrongVersion = NativeDAVEMediaSessionDouble(
            protocolVersion: 2,
            isMediaReady: true
        )
        let mismatchedPlane = makePlane(daveSession: wrongVersion)
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable) {
            _ = try await mismatchedPlane.install(
                makeCapability(generation: 5, daveProtocolVersion: 1)
            )
        }
        #expect(await mismatchedPlane.snapshot().isInstalled == false)

        let unreadySession = NativeDAVEMediaSessionDouble(
            protocolVersion: 1,
            isMediaReady: false
        )
        let unreadyPlane = makePlane(daveSession: unreadySession)
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable) {
            _ = try await unreadyPlane.install(
                makeCapability(generation: 6, daveProtocolVersion: 1)
            )
        }
        #expect(await unreadyPlane.snapshot().isInstalled == false)
    }

    @Test("DAVE transitions re-attest the current session for the installed generation")
    func daveTransitionReattestation() async throws {
        let firstSession = NativeDAVEMediaSessionDouble(
            protocolVersion: 1,
            isMediaReady: true
        )
        let source = NativeDAVEMediaSessionSource(current: firstSession)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await source.provide() },
            datagramTransport: NativeMediaDatagramDouble()
        )
        _ = try await plane.install(
            makeCapability(generation: 9, daveProtocolVersion: 1)
        )

        let secondSession = NativeDAVEMediaSessionDouble(
            protocolVersion: 2,
            isMediaReady: true
        )
        await source.replace(with: secondSession)
        let upgraded = try await plane.updateDAVEProtocolVersion(2, generation: 9)
        #expect(upgraded.dave)
        #expect(upgraded.aead)
        #expect(upgraded.opus)
        #expect(await source.requestCount == 2)

        let disabled = try await plane.updateDAVEProtocolVersion(0, generation: 9)
        #expect(disabled.dave == false)
        #expect(disabled.aead == false)
        #expect(disabled.opus == false)
        #expect(await source.requestCount == 2)

        await #expect(throws: DiscordVoiceNegotiatedMediaError.staleInstallation) {
            _ = try await plane.updateDAVEProtocolVersion(1, generation: 8)
        }
        #expect(await plane.snapshot().isInstalled == false)
    }

    @Test("reset interrupts a suspended install without releasing its generation")
    func resetInterruptsInstall() async throws {
        let session = NativeDAVEMediaSessionDouble(
            protocolVersion: 1,
            isMediaReady: true
        )
        let gate = NativeDAVEProviderGate(session: session)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await gate.provide() },
            datagramTransport: NativeMediaDatagramDouble()
        )
        let capability = try makeCapability(generation: 7, daveProtocolVersion: 1)

        let installation = Task {
            try await plane.install(capability)
        }
        await gate.waitUntilRequested()
        await plane.reset()
        await gate.release()

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.installationInterrupted) {
            _ = try await installation.value
        }
        #expect(await plane.snapshot().isInstalled == false)
        await #expect(throws: DiscordVoiceNegotiatedMediaError.duplicateInstallation) {
            _ = try await plane.install(capability)
        }
    }

    @Test("native failures collapse to redacted media-plane diagnostics")
    func nativeFailureRedaction() async throws {
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { nil },
            datagramTransport: NativeMediaDatagramDouble(),
            makeOpus: {
                throw NativeMediaError.initializationFailed(
                    component: "sensitive-native-detail"
                )
            }
        )

        do {
            _ = try await plane.install(
                makeCapability(generation: 8, daveProtocolVersion: 0)
            )
            Issue.record("Expected the injected native failure")
        } catch let error as DiscordVoiceNativeMediaPlaneError {
            #expect(error == .nativeComponentsUnavailable)
            let rendered = "\(error) \(String(reflecting: error))"
            #expect(rendered.contains("unavailable"))
            #expect(!rendered.contains("sensitive-native-detail"))
        }
        #expect(await plane.snapshot().isInstalled == false)
    }

    private func makePlane(
        daveSession: (any DiscordVoiceNativeDAVEMediaSession)?
    ) -> DiscordVoiceNativeMediaPlane {
        DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: NativeMediaDatagramDouble()
        )
    }

    private func makeCapability(
        generation: UInt64,
        daveProtocolVersion: UInt16
    ) throws -> DiscordVoiceNegotiatedMediaCapability {
        try DiscordVoiceNegotiatedMediaCapability(
            generation: generation,
            ssrc: 0x1111_1111,
            transportMode: .aeadXChaCha20Poly1305RTPSIZE,
            transportKey: [UInt8](repeating: 0xa7, count: 32),
            daveProtocolVersion: daveProtocolVersion
        )
    }
}

private actor NativeDAVEMediaSessionDouble: DiscordVoiceNativeDAVEMediaSession {
    let protocolVersion: UInt16
    let isMediaReady: Bool

    init(protocolVersion: UInt16, isMediaReady: Bool) {
        self.protocolVersion = protocolVersion
        self.isMediaReady = isMediaReady
    }
}

private actor NativeDAVEMediaSessionSource {
    private var currentSession: any DiscordVoiceNativeDAVEMediaSession
    private(set) var requestCount = 0

    init(current: any DiscordVoiceNativeDAVEMediaSession) {
        self.currentSession = current
    }

    func provide() -> any DiscordVoiceNativeDAVEMediaSession {
        requestCount += 1
        return currentSession
    }

    func replace(with session: any DiscordVoiceNativeDAVEMediaSession) {
        currentSession = session
    }
}

private actor NativeDAVEProviderGate {
    private let session: any DiscordVoiceNativeDAVEMediaSession
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(session: any DiscordVoiceNativeDAVEMediaSession) {
        self.session = session
    }

    func provide() async -> (any DiscordVoiceNativeDAVEMediaSession)? {
        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return session
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor NativeMediaDatagramDouble: DiscordVoiceMediaDatagramTransport {
    func sendProtectedPacket(_ bytes: [UInt8]) async throws {}

    func receiveProtectedPacket() async throws -> [UInt8] { [] }

    func disconnect() async {}
}
