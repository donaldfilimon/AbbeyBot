import AbbeyCore
import Foundation
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

    // MARK: - Phase 5: sendAudioFrame

    @Test(
        "sendAudioFrame threads real DAVE protection, correct RTP framing, and unique AEAD counters through the retained transport, after Speaking"
    )
    func sendAudioFrameComposesTheFullSendPath() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let speaking = SpeakingSignalRecorder()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log,
            // Fixed seed: called once by install(), so every packet's
            // sequence/timestamp in this test is deterministic.
            makeRTPClockSeed: { (1_000, 48_000) }
        )
        await plane.attachSpeakingSignal { try await speaking.signal() }
        _ = try await plane.install(
            makeCapability(generation: 20, daveProtocolVersion: 1)
        )

        let receiver = try receiverTransport()
        let rtpCodec = try DiscordVoiceRTPCodec()

        var previousCounter: UInt32?
        for frameIndex in 0..<3 {
            try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: frameIndex))

            #expect(await speaking.callCount == 1)

            let sent = await log.sentPackets
            #expect(sent.count == frameIndex + 1)
            let wirePacket = sent[frameIndex]

            let counter = trailingCounter(wirePacket)
            #expect(counter == UInt32(frameIndex))
            if let previousCounter {
                #expect(counter != previousCounter)
            }
            previousCounter = counter

            let opened = try await receiver.open(wirePacket)
            let header = try rtpCodec.decodeHeader(from: opened)
            #expect(header.ssrc == 0x1111_1111)
            #expect(header.sequence == 1_000 &+ UInt16(frameIndex))
            #expect(header.timestamp == 48_000 &+ UInt32(frameIndex) &* 960)

            let layout = try rtpCodec.plaintextLayout(in: opened)
            let payload = Array(opened[layout.payloadRange])
            let expected = await daveSession.lastProtectedFrame
            let rawInput = await daveSession.lastProtectInputFrame
            #expect(await daveSession.protectCallCount == frameIndex + 1)
            #expect(await daveSession.lastProtectedSSRC == 0x1111_1111)
            #expect(await daveSession.lastProtectedMediaType == .audio)
            #expect(await daveSession.lastProtectedCodec == .opus)
            #expect(payload == Array(expected ?? Data()))
            // The wire payload is DAVE's output, never the raw Opus bytes a
            // bypass would have sent instead.
            #expect(!(rawInput ?? Data()).isEmpty)
            #expect(payload != Array(rawInput ?? Data()))
        }
    }

    @Test("sendAudioFrame fails closed and sends nothing without an installed generation")
    func sendAudioFrameFailsClosedWithoutInstall() async throws {
        let log = NativeMediaDatagramDouble()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { nil },
            datagramTransport: log
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.mediaNotInstalled) {
            try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
    }

    @Test("sendAudioFrame fails closed and sends nothing when DAVE was never attested")
    func sendAudioFrameFailsClosedWithoutDAVE() async throws {
        let log = NativeMediaDatagramDouble()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { nil },
            datagramTransport: log
        )
        let capabilities = try await plane.install(
            makeCapability(generation: 21, daveProtocolVersion: 0)
        )
        #expect(capabilities.dave == false)

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.daveProtectionRequired) {
            try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
    }

    @Test("sendAudioFrame calls the real native protect boundary and fails closed when it is not ready")
    func sendAudioFrameFailsClosedOnRealUnreadyDAVESession() async throws {
        let log = NativeMediaDatagramDouble()
        let readyDouble = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let source = NativeDAVEMediaSessionSource(current: readyDouble)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await source.provide() },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 22, daveProtocolVersion: 1)
        )

        // Swap in the genuine pinned-libdave binding, never activated. Its
        // real `protect()` must fail closed on its own terms; nothing in the
        // send path may substitute a plaintext or double-supplied result.
        let realUnreadySession = try NativeDAVESession(
            protocolVersion: 1,
            groupID: 90_001,
            selfUserID: "90002"
        )
        await source.replace(with: realUnreadySession)

        await #expect(throws: NativeMediaError.daveParticipantUnavailable) {
            try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
    }

    @Test("sendAudioFrame fails closed and sends nothing when DAVE protection itself fails")
    func sendAudioFrameFailsClosedWhenProtectionFails() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 25, daveProtocolVersion: 1)
        )
        await daveSession.failNextProtect(with: TestDAVEProtectionFailure.injected)

        await #expect(throws: TestDAVEProtectionFailure.injected) {
            try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
    }

    @Test("sendAudioFrame fails closed and sends nothing when the Speaking signal fails")
    func sendAudioFrameFailsClosedWhenSpeakingFails() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let speaking = SpeakingSignalRecorder()
        await speaking.markShouldFail()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        await plane.attachSpeakingSignal { try await speaking.signal() }
        _ = try await plane.install(
            makeCapability(generation: 23, daveProtocolVersion: 1)
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.speakingSignalFailed) {
            try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
        #expect(await daveSession.protectCallCount == 0)
        #expect(await speaking.callCount == 1)
    }

    @Test("reset() during a suspended send interrupts it and nothing reaches the retained transport")
    func sendAudioFrameInterruptedByResetSendsNothing() async throws {
        let log = NativeMediaDatagramDouble()
        let bootstrapSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let sendSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        // install() and sendAudioFrame() each call the provider once; only
        // the second (send-time) call is gated, so install() itself never
        // blocks on the gate.
        let gate = SendPathGate(bootstrapSession: bootstrapSession, sendSession: sendSession)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await gate.provide() },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 24, daveProtocolVersion: 1)
        )

        let send = Task {
            try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0))
        }
        await gate.waitUntilRequested()
        await plane.reset()
        await gate.release()

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.sendInterrupted) {
            try await send.value
        }
        #expect(await log.sentPackets.isEmpty)
        #expect(await sendSession.protectCallCount == 0)
        #expect(await plane.snapshot().isInstalled == false)
    }

    private func fixedPCMFrame(seed: Int) -> [Int16] {
        (0..<Opus20msCodec.interleavedSampleCount).map { index in
            Int16(truncatingIfNeeded: (index * 37) + (seed * 911) + 1)
        }
    }

    private func receiverTransport() throws -> DiscordVoiceTransportEncryption {
        try DiscordVoiceTransportEncryption(
            mode: .aeadXChaCha20Poly1305RTPSIZE,
            key: [UInt8](repeating: 0xa7, count: 32),
            primitive: try NativeDiscordVoiceAEADPrimitive(mode: .aeadXChaCha20Poly1305RTPSIZE)
        )
    }

    private func trailingCounter(_ packet: [UInt8]) -> UInt32 {
        packet.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
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
    private(set) var protectCallCount = 0
    private(set) var lastProtectInputFrame: Data?
    private(set) var lastProtectedFrame: Data?
    private(set) var lastProtectedSSRC: UInt32?
    private(set) var lastProtectedMediaType: NativeDAVEMediaType?
    private(set) var lastProtectedCodec: NativeDAVECodec?
    private var forcedFailure: (any Error)?

    init(protocolVersion: UInt16, isMediaReady: Bool) {
        self.protocolVersion = protocolVersion
        self.isMediaReady = isMediaReady
    }

    func failNextProtect(with error: any Error) {
        forcedFailure = error
    }

    /// A deterministic, provably non-identity transform standing in for real
    /// MLS media protection. This repo's Swift surface cannot generate a
    /// valid Commit/Welcome to activate a genuine multi-party libdave roster
    /// (confirmed against the real `NativeDAVESession`: even a self-only
    /// `activateRoster` throws `.daveParticipantUnavailable` without one), so
    /// no test in this environment can produce true MLS ciphertext. XOR by
    /// 0xff is reversible and never equal to a nonempty input, so a send path
    /// that bypassed this call (a plaintext passthrough) is distinguishable
    /// on the wire from one that did not.
    func protect(
        _ frame: Data,
        mediaType: NativeDAVEMediaType,
        codec: NativeDAVECodec,
        ssrc: UInt32
    ) throws -> Data {
        protectCallCount += 1
        lastProtectInputFrame = frame
        lastProtectedSSRC = ssrc
        lastProtectedMediaType = mediaType
        lastProtectedCodec = codec
        if let forcedFailure {
            throw forcedFailure
        }
        let transformed = Data(frame.map { $0 ^ 0xff })
        lastProtectedFrame = transformed
        return transformed
    }
}

private enum TestDAVEProtectionFailure: Error, Equatable {
    case injected
}

private actor SpeakingSignalRecorder {
    private(set) var callCount = 0
    private var shouldFail = false

    func markShouldFail() {
        shouldFail = true
    }

    func signal() throws {
        callCount += 1
        if shouldFail {
            throw TestSpeakingFailure.injected
        }
    }
}

private enum TestSpeakingFailure: Error, Equatable {
    case injected
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

/// Like `NativeDAVEProviderGate`, but only gates the *second* call: the first
/// (install-time) call returns immediately so `install(_:)` never blocks, and
/// only the second (send-time) call suspends until `release()`.
private actor SendPathGate {
    private let bootstrapSession: any DiscordVoiceNativeDAVEMediaSession
    private let sendSession: any DiscordVoiceNativeDAVEMediaSession
    private var callCount = 0
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(
        bootstrapSession: any DiscordVoiceNativeDAVEMediaSession,
        sendSession: any DiscordVoiceNativeDAVEMediaSession
    ) {
        self.bootstrapSession = bootstrapSession
        self.sendSession = sendSession
    }

    func provide() async -> (any DiscordVoiceNativeDAVEMediaSession)? {
        callCount += 1
        guard callCount > 1 else { return bootstrapSession }

        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return sendSession
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
    private(set) var sentPackets: [[UInt8]] = []

    func sendProtectedPacket(_ bytes: [UInt8]) async throws {
        sentPackets.append(bytes)
    }

    func receiveProtectedPacket() async throws -> [UInt8] { [] }

    func disconnect() async {}
}
