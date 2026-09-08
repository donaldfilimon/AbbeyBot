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

    @Test("a failed Speaking signal is re-attempted by the next frame instead of being consumed")
    func failedSpeakingSignalIsRetriedByNextFrame() async throws {
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
            makeCapability(generation: 31, daveProtocolVersion: 1)
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.speakingSignalFailed) {
            try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)

        // The regression this pins: the old one-shot flag was consumed by the
        // failed attempt, so the next frame skipped opcode 5 and reached the
        // transport with no successful Speaking on record. The gate must
        // re-attempt instead.
        await speaking.markShouldSucceed()
        try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 1))
        #expect(await speaking.callCount == 2)
        #expect(await log.sentPackets.count == 1)
    }

    @Test("a frame arriving while Speaking is suspended cannot bypass the gate and reach the transport")
    func concurrentFrameSharesSuspendedSpeakingOutcome() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let speaking = SuspendableSpeakingSignal()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        await plane.attachSpeakingSignal { try await speaking.signal() }
        _ = try await plane.install(
            makeCapability(generation: 32, daveProtocolVersion: 1)
        )

        let first = Task { try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0)) }
        await speaking.waitUntilSignalStarted()
        let second = Task { try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 1)) }
        await Task.yield()
        await speaking.release(failing: true)

        // Under the old eager flag, the second frame observed Speaking as
        // already "sent" while the first callback was still suspended, and
        // proceeded to the transport. Both frames must fail closed and nothing
        // may reach the wire without a successful Speaking.
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.speakingSignalFailed) {
            try await first.value
        }
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.speakingSignalFailed) {
            try await second.value
        }
        #expect(await log.sentPackets.isEmpty)
        #expect(await daveSession.protectCallCount == 0)
    }

    @Test("reset() interrupts a send suspended inside the datagram transport; the packet never reaches the wire")
    func resetInterruptsSuspendedDatagramSend() async throws {
        let transport = SuspendableDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: transport
        )
        _ = try await plane.install(
            makeCapability(generation: 33, daveProtocolVersion: 1)
        )

        let send = Task { try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0)) }
        await transport.waitUntilSendStarted()
        // reset() must cancel and await the suspended send before returning,
        // so the obsolete generation's packet cannot land on the wire during
        // or after teardown.
        await plane.reset()

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.sendInterrupted) {
            try await send.value
        }
        #expect(await transport.deliveredPackets.isEmpty)
        #expect(await plane.snapshot().isInstalled == false)
    }

    @Test("caller cancellation interrupts its audio or video transport task without reset", arguments: [false, true])
    func callerCancellationInterruptsDatagramSend(video: Bool) async throws {
        let transport = SuspendableDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: transport
        )
        _ = try await plane.install(makeCapability(generation: 34, daveProtocolVersion: 1))
        if video {
            await plane.attachVideoAnnouncementSignal { _ in }
            try await plane.installVideoSource(
                allocation: makeVideoAllocation(), activeRIDs: ["100"], codec: .h264
            )
        }
        let send = Task {
            if video {
                try await plane.sendVideoFrame(
                    encodedFrame: Data([0, 0, 0, 1, 0x65, 0x88])
                )
            } else {
                try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0))
            }
        }
        await transport.waitUntilSendStarted()
        send.cancel()
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.sendInterrupted) {
            try await send.value
        }
        #expect(await transport.deliveredPackets.isEmpty)
        #expect(await plane.snapshot().isInstalled)
        await plane.reset()
    }

    @Test("cancelling a send does not cancel the generation-owned Speaking signal")
    func callerCancellationPreservesSpeakingOwnership() async throws {
        let transport = NativeMediaDatagramDouble()
        let speaking = SuspendableSpeakingSignal()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: transport
        )
        await plane.attachSpeakingSignal { try await speaking.signal() }
        _ = try await plane.install(makeCapability(generation: 35, daveProtocolVersion: 1))
        let first = Task { try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 0)) }
        await speaking.waitUntilSignalStarted()
        first.cancel()
        await speaking.release(failing: false)
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.sendInterrupted) {
            try await first.value
        }
        try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 1))
        #expect(await speaking.callCount == 1)
        #expect(await transport.sentPackets.count == 1)
    }

    // MARK: - Video send boundary (Phase 5 pattern extended to .video)

    @Test(
        "sendVideoFrame threads real DAVE video protection, 90 kHz RTP framing with the negotiated payload type and marker, and the shared AEAD counter through the retained transport, after the Opcode 12 announcement"
    )
    func sendVideoFrameComposesTheFullSendPath() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let speaking = SpeakingSignalRecorder()
        let announcements = VideoAnnouncementRecorder()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log,
            // Fixed seed: install() consumes it for the audio clock and
            // installVideoSource() for the video clock, so every packet's
            // sequence/timestamp in this test is deterministic.
            makeRTPClockSeed: { (5_000, 90_000) }
        )
        await plane.attachSpeakingSignal { try await speaking.signal() }
        await plane.attachVideoAnnouncementSignal { try await announcements.signal($0) }
        _ = try await plane.install(
            makeCapability(generation: 40, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        let receiver = try receiverTransport()
        let rtpCodec = try DiscordVoiceRTPCodec()

        // One audio frame first: audio and video share one transport
        // encryption instance, so their AEAD nonce counters must come from
        // the same never-reused sequence.
        try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 9))
        #expect(trailingCounter(await log.sentPackets[0]) == 0)

        for frameIndex in 0..<3 {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: frameIndex))

            // The Opcode 12 announcement fired exactly once, before the first
            // video packet, carrying the server-assigned allocation.
            #expect(await announcements.callCount == 1)
            let announced = try #require(await announcements.announcements.first)
            #expect(announced.audioSSRC == 0x1111_1111)
            #expect(announced.videoSSRC == 0x2222_2222)
            #expect(announced.streams.count == 1)
            #expect(await speaking.callCount == 1)

            let sent = await log.sentPackets
            #expect(sent.count == frameIndex + 2)
            let wirePacket = sent[frameIndex + 1]

            // Shared transport: video counters continue after the audio one.
            #expect(trailingCounter(wirePacket) == UInt32(frameIndex + 1))

            let opened = try await receiver.open(wirePacket)
            let header = try rtpCodec.decodeHeader(from: opened)
            #expect(header.ssrc == 0x2222_2222)
            #expect(header.payloadType == DiscordVoiceRTPHeader.discordVideoH264PayloadType)
            #expect(header.marker == true)
            #expect(header.sequence == 5_000 &+ UInt16(frameIndex))
            #expect(header.timestamp == 90_000 &+ UInt32(frameIndex) &* 3_000)

            let layout = try rtpCodec.plaintextLayout(in: opened)
            let payload = Array(opened[layout.payloadRange])
            let expected = await daveSession.lastProtectedFrame
            let rawInput = await daveSession.lastProtectInputFrame
            #expect(await daveSession.protectCallCount == frameIndex + 2)
            #expect(await daveSession.lastProtectedSSRC == 0x2222_2222)
            #expect(await daveSession.lastProtectedMediaType == .video)
            #expect(await daveSession.lastProtectedCodec == .h264)
            let expectedUnits = try DiscordVoiceH264Packetizer.nalUnits(
                in: Array(expected ?? Data())
            )
            #expect(payload == expectedUnits.first)
            // The wire payload is DAVE's output, never the raw encoded frame
            // a bypass would have sent instead.
            #expect(!(rawInput ?? Data()).isEmpty)
            #expect(payload != Array(rawInput ?? Data()))
        }

        // Teardown drops the video source with the generation; nothing more
        // can reach the socket.
        await plane.reset()
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.mediaNotInstalled) {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 9))
        }
        #expect(await log.sentPackets.count == 4)
        #expect(await announcements.callCount == 1)
    }

    @Test("sendVideoFrame fails closed and sends nothing without an installed generation")
    func sendVideoFrameFailsClosedWithoutInstall() async throws {
        let log = NativeMediaDatagramDouble()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { nil },
            datagramTransport: log
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.mediaNotInstalled) {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
    }

    @Test("sendVideoFrame fails closed and sends nothing without an installed video source")
    func sendVideoFrameFailsClosedWithoutVideoSource() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 41, daveProtocolVersion: 1)
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoSourceNotInstalled) {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
        #expect(await daveSession.protectCallCount == 0)
    }

    @Test("video source install and send both fail closed when DAVE was never attested — no transport-only video path exists")
    func videoSourceRequiresDAVE() async throws {
        let log = NativeMediaDatagramDouble()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { nil },
            datagramTransport: log
        )
        let capabilities = try await plane.install(
            makeCapability(generation: 42, daveProtocolVersion: 0)
        )
        #expect(capabilities.dave == false)

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.daveProtectionRequired) {
            try await plane.installVideoSource(
                allocation: makeVideoAllocation(),
                activeRIDs: ["100"],
                codec: .h264
            )
        }
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.daveProtectionRequired) {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
    }

    @Test("installVideoSource rejects foreign allocations and non-video codecs")
    func installVideoSourceRejectsInvalidSources() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 43, daveProtocolVersion: 1)
        )

        // An allocation whose audio SSRC is not this connection's cannot bind.
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoSourceInvalid) {
            try await plane.installVideoSource(
                allocation: makeVideoAllocation(audioSSRC: 0x9999_9999),
                activeRIDs: ["100"],
                codec: .h264
            )
        }
        // Opus is not a video codec; H.265 has no modeled payload type.
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoSourceInvalid) {
            try await plane.installVideoSource(
                allocation: makeVideoAllocation(),
                activeRIDs: ["100"],
                codec: .vp8
            )
        }
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoSourceInvalid) {
            try await plane.installVideoSource(
                allocation: makeVideoAllocation(),
                activeRIDs: ["100"],
                codec: .opus
            )
        }
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoSourceInvalid) {
            try await plane.installVideoSource(
                allocation: makeVideoAllocation(),
                activeRIDs: ["100"],
                codec: .h265
            )
        }
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoSourceNotInstalled) {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
    }

    @Test("sendVideoFrame rejects an empty frame before reserving any state")
    func sendVideoFrameRejectsEmptyFrame() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let announcements = VideoAnnouncementRecorder()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        await plane.attachVideoAnnouncementSignal { try await announcements.signal($0) }
        _ = try await plane.install(
            makeCapability(generation: 44, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoFrameInvalid) {
            try await plane.sendVideoFrame(encodedFrame: Data())
        }
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoFrameInvalid) {
            try await plane.sendVideoFrame(encodedFrame: Data([0, 0, 0, 1, 0xe5, 1]))
        }
        var oversized = Data([0, 0, 0, 1, 0x65])
        oversized.append(Data(
            repeating: 1,
            count: DiscordVoiceH264Packetizer.maximumAccessUnitBytes
        ))
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoFrameInvalid) {
            try await plane.sendVideoFrame(encodedFrame: oversized)
        }
        #expect(await log.sentPackets.isEmpty)
        #expect(await announcements.callCount == 0)
        #expect(await daveSession.protectCallCount == 0)
    }

    @Test("sendVideoFrame fails closed and sends nothing when the Opcode 12 announcement fails")
    func sendVideoFrameFailsClosedWhenAnnouncementFails() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let announcements = VideoAnnouncementRecorder()
        await announcements.markShouldFail()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        await plane.attachVideoAnnouncementSignal { try await announcements.signal($0) }
        _ = try await plane.install(
            makeCapability(generation: 45, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoAnnouncementSignalFailed) {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
        #expect(await daveSession.protectCallCount == 0)
        #expect(await announcements.callCount == 1)
    }

    @Test("sendVideoFrame fails closed without an attached announcement callback — the Opcode 12 obligation cannot be skipped")
    func sendVideoFrameFailsClosedWithoutAnnouncementSignal() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 46, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.videoAnnouncementSignalFailed) {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
        #expect(await daveSession.protectCallCount == 0)
    }

    @Test("sendVideoFrame fails closed and sends nothing when DAVE protection itself fails")
    func sendVideoFrameFailsClosedWhenProtectionFails() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let announcements = VideoAnnouncementRecorder()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        await plane.attachVideoAnnouncementSignal { try await announcements.signal($0) }
        _ = try await plane.install(
            makeCapability(generation: 47, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )
        await daveSession.failNextProtect(with: TestDAVEProtectionFailure.injected)

        await #expect(throws: TestDAVEProtectionFailure.injected) {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
    }

    @Test("sendVideoFrame calls the real native protect boundary and fails closed when it is not ready")
    func sendVideoFrameFailsClosedOnRealUnreadyDAVESession() async throws {
        let log = NativeMediaDatagramDouble()
        let readyDouble = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let source = NativeDAVEMediaSessionSource(current: readyDouble)
        let announcements = VideoAnnouncementRecorder()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await source.provide() },
            datagramTransport: log
        )
        await plane.attachVideoAnnouncementSignal { try await announcements.signal($0) }
        _ = try await plane.install(
            makeCapability(generation: 48, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        // Swap in the genuine pinned-libdave binding, never activated. Its
        // real `protect()` must fail closed on its own terms; nothing in the
        // video send path may substitute a plaintext or double-supplied result.
        let realUnreadySession = try NativeDAVESession(
            protocolVersion: 1,
            groupID: 91_001,
            selfUserID: "91002"
        )
        await source.replace(with: realUnreadySession)

        await #expect(throws: NativeMediaError.daveParticipantUnavailable) {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
        }
        #expect(await log.sentPackets.isEmpty)
    }

    @Test("reset() during a suspended video send interrupts it and nothing reaches the retained transport")
    func sendVideoFrameInterruptedByResetSendsNothing() async throws {
        let log = NativeMediaDatagramDouble()
        let bootstrapSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let sendSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let announcements = VideoAnnouncementRecorder()
        // install() and sendVideoFrame() each call the provider once; only
        // the second (send-time) call is gated, so install() itself never
        // blocks on the gate.
        let gate = SendPathGate(bootstrapSession: bootstrapSession, sendSession: sendSession)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await gate.provide() },
            datagramTransport: log
        )
        await plane.attachVideoAnnouncementSignal { try await announcements.signal($0) }
        _ = try await plane.install(
            makeCapability(generation: 49, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        let send = Task {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
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

    @Test(
        "a superseding installVideoSource interrupts a video send suspended on DAVE work — no packet under the obsolete SSRC reaches the transport"
    )
    func supersedingVideoSourceInterruptsSendSuspendedOnDAVE() async throws {
        let log = NativeMediaDatagramDouble()
        let bootstrapSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let sendSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let announcements = VideoAnnouncementRecorder()
        // install() and sendVideoFrame() each call the provider once; only
        // the second (send-time) call is gated.
        let gate = SendPathGate(bootstrapSession: bootstrapSession, sendSession: sendSession)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await gate.provide() },
            datagramTransport: log
        )
        await plane.attachVideoAnnouncementSignal { try await announcements.signal($0) }
        _ = try await plane.install(
            makeCapability(generation: 50, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        let send = Task {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 0))
        }
        await gate.waitUntilRequested()

        // The outbound source is switched (a camera/screen swap) while that
        // send is still suspended. The generation is unchanged, so the send's
        // `revision` check still passes — only the video-source generation
        // can fail it closed.
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(videoSSRC: 0x3333_3333),
            activeRIDs: ["100"],
            codec: .h264
        )
        await gate.release()

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.sendInterrupted) {
            try await send.value
        }
        #expect(await log.sentPackets.isEmpty)
        #expect(await sendSession.protectCallCount == 0)
        // The only announcement that fired belongs to the superseded source;
        // the new source has not announced and no frame carried either SSRC.
        #expect(await announcements.callCount == 1)
        #expect(await announcements.announcements.first?.videoSSRC == 0x2222_2222)
        // The audio generation is untouched: replacing a video source must
        // not tear down the installed connection.
        #expect(await plane.snapshot().isInstalled)
    }

    @Test(
        "a superseding installVideoSource interrupts a video send suspended on its Opcode 12 announcement"
    )
    func supersedingVideoSourceInterruptsSendSuspendedOnAnnouncement() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let announcements = SuspendableVideoAnnouncementSignal()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        await plane.attachVideoAnnouncementSignal { try await announcements.signal($0) }
        _ = try await plane.install(
            makeCapability(generation: 51, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        let send = Task {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 1))
        }
        await announcements.waitUntilSignalStarted()

        // Installing a source re-arms the announcement gate, so the suspended
        // send's callback can no longer latch it. Nothing but the video-source
        // generation stops that send from continuing to the wire.
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(videoSSRC: 0x4444_4444),
            activeRIDs: ["100"],
            codec: .h264
        )
        await announcements.release()

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.sendInterrupted) {
            try await send.value
        }
        #expect(await log.sentPackets.isEmpty)
        #expect(await daveSession.protectCallCount == 0)
        #expect(await announcements.callCount == 1)
        #expect(await announcements.announcements.first?.videoSSRC == 0x2222_2222)
        #expect(await plane.snapshot().isInstalled)
    }

    @Test("after a video source is replaced, the next frame announces and sends under the new source")
    func replacedVideoSourceIsUsedByLaterFrames() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let announcements = VideoAnnouncementRecorder()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        await plane.attachVideoAnnouncementSignal { try await announcements.signal($0) }
        _ = try await plane.install(
            makeCapability(generation: 52, daveProtocolVersion: 1)
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )
        try await plane.installVideoSource(
            allocation: makeVideoAllocation(videoSSRC: 0x5555_5555),
            activeRIDs: ["100"],
            codec: .h264
        )

        try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 2))

        #expect(await announcements.callCount == 1)
        #expect(await announcements.announcements.first?.videoSSRC == 0x5555_5555)
        let receiver = try receiverTransport()
        let rtpCodec = try DiscordVoiceRTPCodec()
        let wirePacket = try #require(await log.sentPackets.first)
        let opened = try await receiver.open(wirePacket)
        let header = try rtpCodec.decodeHeader(from: opened)
        #expect(header.ssrc == 0x5555_5555)
        #expect(header.payloadType == DiscordVoiceRTPHeader.discordVideoH264PayloadType)
        #expect(await daveSession.lastProtectedSSRC == 0x5555_5555)
        #expect(await daveSession.lastProtectedCodec == .h264)
    }

    // MARK: - Receive boundary (§1: AEAD open -> DAVE unprotect -> Opus decode)

    @Test(
        "receiveAudioFrame mirrors the send path: a sealed packet round-trips through AEAD open, the real DAVE unprotect boundary, and Opus decode"
    )
    func receiveAudioFrameRoundTripsTheSendPath() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log,
            makeRTPClockSeed: { (2_000, 96_000) }
        )
        _ = try await plane.install(
            makeCapability(generation: 60, daveProtocolVersion: 1)
        )

        try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 3))
        let wirePacket = try #require(await log.sentPackets.first)
        let sentOpusPayload = try #require(await daveSession.lastProtectInputFrame)

        let frame = try await plane.receiveAudioFrame(packet: wirePacket, senderID: 7_701)

        // DAVE `unprotect` was actually invoked — for audio, with the
        // caller-supplied MLS participant — and what reached the decoder is
        // exactly the Opus payload the encoder produced. A path that skipped
        // DAVE would have handed the decoder the on-wire (XOR-transformed)
        // bytes instead, which the last expectation pins as different.
        #expect(await daveSession.unprotectCallCount == 1)
        #expect(await daveSession.lastUnprotectedMediaType == .audio)
        #expect(await daveSession.lastUnprotectedSenderID == 7_701)
        #expect(await daveSession.lastUnprotectOutputFrame == sentOpusPayload)
        #expect(await daveSession.lastUnprotectInputFrame != sentOpusPayload)

        // Identity comes from the authenticated header, not from the caller.
        #expect(frame.ssrc == 0x1111_1111)
        #expect(frame.sequence == 2_000)
        #expect(frame.timestamp == 96_000)

        // The PCM corresponds to the input: an independent, freshly created
        // Opus decoder fed exactly this one payload produces exactly this
        // output. Deterministic, with no tolerance hand-waving.
        let reference = try Opus20msCodec()
        let expectedPCM = try await reference.decode(Array(sentOpusPayload))
        #expect(frame.pcm == expectedPCM)
        #expect(frame.pcm.count == Opus20msCodec.interleavedSampleCount)
        #expect(frame.pcm.contains { $0 != 0 })

        let diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.accepted == 1)
        #expect(diagnostics.activeAudioSources == 1)

        // Neither the frame nor the diagnostics may render PCM or packet bytes.
        let rendered = "\(frame) \(String(reflecting: frame)) \(diagnostics)"
        #expect(rendered.contains("samples: \(Opus20msCodec.interleavedSampleCount)"))
        #expect(!rendered.contains("["))
        #expect(!"\(diagnostics)".contains("286331153"))
        let mirrored = Mirror(reflecting: frame).children.map { "\($0.value)" }.joined()
        #expect(mirrored == "<redacted>")
    }

    @Test("receiveAudioFrame fails closed and yields no audio without an installed generation")
    func receiveAudioFrameFailsClosedWithoutInstall() async throws {
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: NativeMediaDatagramDouble()
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.mediaNotInstalled) {
            _ = try await plane.receiveAudioFrame(packet: [0x80, 0x78], senderID: 1)
        }
        #expect(await daveSession.unprotectCallCount == 0)
        let diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.accepted == 0)
        #expect(diagnostics.droppedNotInstalled == 1)
        #expect(diagnostics.activeAudioSources == 0)
    }

    @Test("receiveAudioFrame fails closed and yields no audio when DAVE was never attested")
    func receiveAudioFrameFailsClosedWithoutDAVE() async throws {
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: NativeMediaDatagramDouble()
        )
        // Protocol version 0 installs AEAD and Opus but never attests DAVE.
        // There is no transport-only receive path.
        let capabilities = try await plane.install(
            makeCapability(generation: 61, daveProtocolVersion: 0)
        )
        #expect(capabilities.dave == false)

        let sender = try senderTransport()
        let packet = try await makeIncomingAudioPacket(
            sender: sender,
            ssrc: 0x7777_7777,
            sequence: 5,
            timestamp: 960,
            opusPayload: try await fixedOpusPayload(seed: 4)
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.daveProtectionRequired) {
            _ = try await plane.receiveAudioFrame(packet: packet, senderID: 7_702)
        }
        #expect(await daveSession.unprotectCallCount == 0)
        #expect(await plane.receiveDiagnostics().droppedNotInstalled == 1)
    }

    @Test(
        "a packet that fails RTPSIZE authentication yields no audio, is counted, and never reaches DAVE"
    )
    func receiveAudioFrameFailsClosedOnAEADFailure() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 62, daveProtocolVersion: 1)
        )
        try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 5))
        var tampered = try #require(await log.sentPackets.first)
        // One flipped ciphertext byte, past the clear RTP header.
        tampered[DiscordVoiceRTPHeader.baseLength + 2] ^= 0x01

        await #expect(
            throws: DiscordVoiceNativeMediaPlaneError.receiveTransportAuthenticationFailed
        ) {
            _ = try await plane.receiveAudioFrame(packet: tampered, senderID: 7_703)
        }
        #expect(await daveSession.unprotectCallCount == 0)
        let diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.accepted == 0)
        #expect(diagnostics.droppedTransportAuthentication == 1)
        // No decoder state is created from an unauthenticated packet.
        #expect(diagnostics.activeAudioSources == 0)
    }

    @Test("a packet whose DAVE unprotect fails yields no audio, is counted, and creates no decoder")
    func receiveAudioFrameFailsClosedOnDAVEFailure() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 63, daveProtocolVersion: 1)
        )
        try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 6))
        let wirePacket = try #require(await log.sentPackets.first)
        await daveSession.failNextUnprotect(with: TestDAVEProtectionFailure.injected)

        // The injected native detail is collapsed into a payload-free
        // media-plane case: a packet-driven caller learns nothing but that the
        // frame was refused.
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receiveDAVEUnprotectFailed) {
            _ = try await plane.receiveAudioFrame(packet: wirePacket, senderID: 7_704)
        }
        #expect(await daveSession.unprotectCallCount == 1)
        let diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.accepted == 0)
        #expect(diagnostics.droppedDAVE == 1)
        #expect(diagnostics.activeAudioSources == 0)
    }

    @Test(
        "the real native DAVE unprotect boundary is called and fails closed when the session is not ready"
    )
    func receiveAudioFrameFailsClosedOnRealUnreadyDAVESession() async throws {
        let log = NativeMediaDatagramDouble()
        let readyDouble = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let source = NativeDAVEMediaSessionSource(current: readyDouble)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await source.provide() },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 64, daveProtocolVersion: 1)
        )
        try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 7))
        let wirePacket = try #require(await log.sentPackets.first)

        // Swap in the genuine pinned-libdave binding, never activated. Its
        // real `unprotect()` must fail closed on its own terms; nothing in the
        // receive path may substitute a plaintext or double-supplied result.
        let realUnreadySession = try NativeDAVESession(
            protocolVersion: 1,
            groupID: 92_001,
            selfUserID: "92002"
        )
        await source.replace(with: realUnreadySession)

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receiveDAVEUnprotectFailed) {
            _ = try await plane.receiveAudioFrame(packet: wirePacket, senderID: 92_003)
        }
        let diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.accepted == 0)
        #expect(diagnostics.droppedDAVE == 1)
        #expect(diagnostics.activeAudioSources == 0)
    }

    @Test("malformed and payload-free packets yield no audio and are counted as malformed")
    func receiveAudioFrameFailsClosedOnMalformedPacket() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        _ = try await plane.install(
            makeCapability(generation: 65, daveProtocolVersion: 1)
        )
        try await plane.sendAudioFrame(pcm: fixedPCMFrame(seed: 8))
        let wirePacket = try #require(await log.sentPackets.first)

        // Empty, and truncated below a fixed RTP header.
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receivePacketMalformed) {
            _ = try await plane.receiveAudioFrame(packet: [], senderID: 7_705)
        }
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receivePacketMalformed) {
            _ = try await plane.receiveAudioFrame(
                packet: Array(wirePacket.prefix(8)),
                senderID: 7_705
            )
        }

        // A packet that authenticates but carries no payload at all must not
        // reach DAVE or the decoder either.
        let sender = try senderTransport()
        let rtpCodec = try DiscordVoiceRTPCodec()
        let emptyBodied = try await sender.seal(
            rtpCodec.encode(
                try DiscordVoiceRTPHeader(sequence: 1, timestamp: 960, ssrc: 0x7777_7777)
            )
        )
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receivePacketMalformed) {
            _ = try await plane.receiveAudioFrame(packet: emptyBodied, senderID: 7_705)
        }

        #expect(await daveSession.unprotectCallCount == 0)
        let diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.accepted == 0)
        #expect(diagnostics.droppedMalformed == 3)
        #expect(diagnostics.activeAudioSources == 0)
    }

    @Test(
        "a well-formed video packet is refused as an unsupported media type, never handed to the audio DAVE boundary"
    )
    func receiveAudioFrameRefusesVideoPayloadTypes() async throws {
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: NativeMediaDatagramDouble()
        )
        _ = try await plane.install(
            makeCapability(generation: 66, daveProtocolVersion: 1)
        )

        // `DiscordVoiceRTPHeader.acceptedPayloadTypes` admits the negotiated
        // video payload types, so this packet decodes as a valid header.
        let sender = try senderTransport()
        let packet = try await makeIncomingAudioPacket(
            sender: sender,
            ssrc: 0x7777_7777,
            sequence: 2,
            timestamp: 960,
            payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
            opusPayload: try await fixedOpusPayload(seed: 9)
        )

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receiveMediaTypeUnsupported) {
            _ = try await plane.receiveAudioFrame(packet: packet, senderID: 7_706)
        }
        #expect(await daveSession.unprotectCallCount == 0)
        let diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.droppedMediaTypeUnsupported == 1)
        #expect(diagnostics.activeAudioSources == 0)
    }

    @Test(
        "reset() during a suspended receive interrupts it: no audio is returned and the packet is counted as interrupted"
    )
    func receiveAudioFrameInterruptedBySupersedingReset() async throws {
        let bootstrapSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let receiveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        // install() and receiveAudioFrame() each call the provider once; only
        // the second (receive-time) call is gated.
        let gate = SendPathGate(
            bootstrapSession: bootstrapSession,
            sendSession: receiveSession
        )
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await gate.provide() },
            datagramTransport: NativeMediaDatagramDouble()
        )
        _ = try await plane.install(
            makeCapability(generation: 67, daveProtocolVersion: 1)
        )

        let sender = try senderTransport()
        let packet = try await makeIncomingAudioPacket(
            sender: sender,
            ssrc: 0x7777_7777,
            sequence: 3,
            timestamp: 960,
            opusPayload: try await fixedOpusPayload(seed: 10)
        )

        let receive = Task {
            try await plane.receiveAudioFrame(packet: packet, senderID: 7_707)
        }
        await gate.waitUntilRequested()
        await plane.reset()
        await gate.release()

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receiveInterrupted) {
            _ = try await receive.value
        }
        #expect(await receiveSession.unprotectCallCount == 0)
        let diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.accepted == 0)
        #expect(diagnostics.droppedInterrupted == 1)
        // Teardown dropped every decoder with the generation.
        #expect(diagnostics.activeAudioSources == 0)
    }

    @Test(
        "each SSRC decodes on its own Opus decoder: two sources are independent, one source is continuous, and eviction is caller-driven"
    )
    func receiveAudioFrameKeepsOneDecoderPerSource() async throws {
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: NativeMediaDatagramDouble()
        )
        _ = try await plane.install(
            makeCapability(generation: 68, daveProtocolVersion: 1)
        )

        let sender = try senderTransport()
        let firstPayload = try await fixedOpusPayload(seed: 11)
        let secondPayload = try await fixedOpusPayload(seed: 12)

        let alphaFirst = try await plane.receiveAudioFrame(
            packet: try await makeIncomingAudioPacket(
                sender: sender,
                ssrc: 0x7777_7777,
                sequence: 10,
                timestamp: 960,
                opusPayload: firstPayload
            ),
            senderID: 7_708
        )
        // The same payload from a different SSRC must decode on its own fresh
        // decoder. A shared decoder would carry alpha's state into beta and
        // produce different samples here.
        let betaFirst = try await plane.receiveAudioFrame(
            packet: try await makeIncomingAudioPacket(
                sender: sender,
                ssrc: 0x8888_8888,
                sequence: 20,
                timestamp: 1_920,
                opusPayload: firstPayload
            ),
            senderID: 7_709
        )
        #expect(betaFirst.pcm == alphaFirst.pcm)
        #expect(betaFirst.ssrc == 0x8888_8888)

        // Alpha's second frame must continue alpha's decoder state, matching a
        // reference decoder driven with the same two payloads in order.
        let alphaSecond = try await plane.receiveAudioFrame(
            packet: try await makeIncomingAudioPacket(
                sender: sender,
                ssrc: 0x7777_7777,
                sequence: 11,
                timestamp: 1_920,
                opusPayload: secondPayload
            ),
            senderID: 7_708
        )
        let reference = try Opus20msCodec()
        _ = try await reference.decode(firstPayload)
        let expectedSecond = try await reference.decode(secondPayload)
        #expect(alphaSecond.pcm == expectedSecond)

        var diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.accepted == 3)
        #expect(diagnostics.activeAudioSources == 2)

        // Eviction policy (idle timeout, clock) belongs to the portable layer;
        // the plane only exposes the lifetime hook it drives.
        #expect(await plane.releaseAudioSource(ssrc: 0x8888_8888))
        #expect(await plane.releaseAudioSource(ssrc: 0x8888_8888) == false)
        diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.activeAudioSources == 1)
    }

    @Test(
        "concealAudioLoss continues an authenticated source and refuses to fabricate one that was never authenticated"
    )
    func concealAudioLossOnlyContinuesAuthenticatedSources() async throws {
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: NativeMediaDatagramDouble()
        )
        _ = try await plane.install(
            makeCapability(generation: 69, daveProtocolVersion: 1)
        )

        // No packet from this source has ever authenticated, so there is no
        // decoder state to continue and nothing may be synthesized.
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receiveSourceUnknown) {
            _ = try await plane.concealAudioLoss(ssrc: 0x7777_7777)
        }
        #expect(await plane.receiveDiagnostics().droppedSourceUnknown == 1)

        let sender = try senderTransport()
        let payload = try await fixedOpusPayload(seed: 13)
        _ = try await plane.receiveAudioFrame(
            packet: try await makeIncomingAudioPacket(
                sender: sender,
                ssrc: 0x7777_7777,
                sequence: 30,
                timestamp: 960,
                opusPayload: payload
            ),
            senderID: 7_710
        )

        let concealed = try await plane.concealAudioLoss(ssrc: 0x7777_7777)
        let reference = try Opus20msCodec()
        _ = try await reference.decode(payload)
        #expect(concealed == (try await reference.decodePacketLoss()))
        #expect(concealed.count == Opus20msCodec.interleavedSampleCount)

        let diagnostics = await plane.receiveDiagnostics()
        #expect(diagnostics.concealed == 1)
        #expect(diagnostics.accepted == 1)

        // Eviction removes the state concealment depends on, so concealment
        // for that source fails closed again.
        #expect(await plane.releaseAudioSource(ssrc: 0x7777_7777))
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receiveSourceUnknown) {
            _ = try await plane.concealAudioLoss(ssrc: 0x7777_7777)
        }
    }

    /// The remote side of a Discord voice room: the same construction as
    /// `receiverTransport()` (same negotiated key), but used to seal packets
    /// *into* the plane under test rather than to open packets it sent. It
    /// must be a separate instance — send nonce counters and per-SSRC replay
    /// windows are not shared between the two roles.
    private func senderTransport() throws -> DiscordVoiceTransportEncryption {
        try receiverTransport()
    }

    /// Builds one inbound wire packet the way a remote client would: RTP
    /// header, DAVE-protected Opus body (XOR by 0xff, the exact transform
    /// `NativeDAVEMediaSessionDouble` inverts), then RTPSIZE sealing.
    private func makeIncomingAudioPacket(
        sender: DiscordVoiceTransportEncryption,
        ssrc: UInt32,
        sequence: UInt16,
        timestamp: UInt32,
        payloadType: UInt8 = DiscordVoiceRTPHeader.discordAudioPayloadType,
        opusPayload: [UInt8]
    ) async throws -> [UInt8] {
        let header = try DiscordVoiceRTPHeader(
            payloadType: payloadType,
            sequence: sequence,
            timestamp: timestamp,
            ssrc: ssrc
        )
        let rtpCodec = try DiscordVoiceRTPCodec()
        let daveProtectedBody = opusPayload.map { $0 ^ 0xff }
        return try await sender.seal(try rtpCodec.encode(header) + daveProtectedBody)
    }

    private func fixedOpusPayload(seed: Int) async throws -> [UInt8] {
        let codec = try Opus20msCodec()
        return try await codec.encode(fixedPCMFrame(seed: seed))
    }

    @Test("a video frame above MTU is fragmented: one timestamp, contiguous sequences, marker only on the last")
    func videoFrameAboveMTUIsFragmented() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let announcements = VideoAnnouncementRecorder()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: log
        )
        await plane.attachVideoAnnouncementSignal { announcement in
            try await announcements.signal(announcement)
        }
        _ = try await plane.install(makeCapability(generation: 90, daveProtocolVersion: 1))
        try await plane.installVideoSource(
            allocation: try makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        // Comfortably past the 1200-byte sealed budget, so this must fragment.
        let big = Data([0, 0, 0, 1, 0x65]
            + (0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        try await plane.sendVideoFrame(encodedFrame: big)

        let packets = await log.sentPackets
        #expect(packets.count > 1)

        let receiver = try receiverTransport()
        var headers: [DiscordVoiceRTPHeader] = []
        var depacketizer = DiscordVoiceH264Depacketizer()
        var reassembled: [UInt8]?
        let codec = try DiscordVoiceRTPCodec()
        for packet in packets {
            let opened = try await receiver.open(packet)
            let header = try codec.decodeHeader(from: opened)
            headers.append(header)
            let layout = try codec.plaintextLayout(in: opened)
            reassembled = try depacketizer.insert(.init(
                header: header,
                payload: Array(opened[layout.payloadRange])
            )) ?? reassembled
            // Every fragment must still fit the path MTU once sealed — the
            // failure mode a naive fragmenter hides until it hits the wire.
            #expect(packet.count <= DiscordVoiceVideoPacketizer.defaultPathMTU)
        }

        // The regression this pins: one packet per frame with marker always
        // true. A fragmented frame carries exactly one marker, on the last
        // fragment, one shared timestamp, and contiguous sequence numbers.
        #expect(headers.filter(\.marker).count == 1)
        #expect(headers.last?.marker == true)
        #expect(Set(headers.map(\.timestamp)).count == 1)
        let sequences = headers.map(\.sequence)
        #expect(sequences == Array(sequences.map { $0 }).sorted())
        for (index, sequence) in sequences.enumerated() where index > 0 {
            #expect(sequence == sequences[index - 1] &+ 1)
        }

        // Reassembly reproduces exactly what DAVE produced — no fragment lost
        // or duplicated on the way out.
        let protected = await daveSession.lastProtectedFrame
        #expect(reassembled == Array(protected ?? Data()))
        #expect(await announcements.callCount == 1)
    }

    @Test("overlapping video sends reserve disjoint RTP sequence runs after protected sizes are known")
    func overlappingVideoSendsReserveDisjointRTPRuns() async throws {
        let log = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let provider = ConcurrentSendPathGate(session: daveSession)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { await provider.provide() },
            datagramTransport: log,
            makeRTPClockSeed: { (5_000, 90_000) }
        )
        await plane.attachVideoAnnouncementSignal { _ in }
        _ = try await plane.install(makeCapability(generation: 901, daveProtocolVersion: 1))
        try await plane.installVideoSource(
            allocation: try makeVideoAllocation(), activeRIDs: ["100"], codec: .h264
        )

        let first = Task {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 21))
        }
        let second = Task {
            try await plane.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 22))
        }
        await provider.waitUntilSendRequests(2)
        await provider.release()
        try await first.value
        try await second.value

        let receiver = try receiverTransport()
        let codec = try DiscordVoiceRTPCodec()
        var headers: [DiscordVoiceRTPHeader] = []
        for packet in await log.sentPackets {
            headers.append(try codec.decodeHeader(from: await receiver.open(packet)))
        }
        #expect(headers.count == 2)
        #expect(Set(headers.map(\.sequence)) == Set([5_000, 5_001]))
        #expect(Set(headers.map(\.timestamp)) == Set([90_000, 93_000]))
    }

    @Test("a video source installed mid-frame stops the remaining fragments")
    func videoSourceSwapMidFrameStopsRemainingFragments() async throws {
        let transport = SuspendableDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: transport
        )
        await plane.attachVideoAnnouncementSignal { _ in }
        _ = try await plane.install(makeCapability(generation: 91, daveProtocolVersion: 1))
        try await plane.installVideoSource(
            allocation: try makeVideoAllocation(),
            activeRIDs: ["100"],
            codec: .h264
        )

        let big = Data([0, 0, 0, 1, 0x65]
            + (0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })
        let send = Task { try await plane.sendVideoFrame(encodedFrame: big) }
        // Park inside the first fragment's transport write, then swap sources.
        await transport.waitUntilSendStarted()
        try await plane.installVideoSource(
            allocation: try makeVideoAllocation(videoSSRC: 0x3333_3333),
            activeRIDs: ["100"],
            codec: .h264
        )
        await transport.release()

        await #expect(throws: DiscordVoiceNativeMediaPlaneError.sendInterrupted) {
            try await send.value
        }
        // The per-fragment check is what stops this: without it the remaining
        // fragments would go out under the obsolete SSRC, stranding a partial
        // frame at the receiver.
        #expect(await transport.deliveredPackets.count < 4)
    }

    @Test("H264 receive authenticates packets, depacketizes before DAVE unprotect, and returns one access unit")
    func h264ReceiveUsesProtocolDefinedProtectionOrder() async throws {
        let wire = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let sender = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: wire,
            makeRTPClockSeed: { (65_534, 90_000) }
        )
        await sender.attachVideoAnnouncementSignal { _ in }
        _ = try await sender.install(makeCapability(generation: 95, daveProtocolVersion: 1))
        try await sender.installVideoSource(
            allocation: try makeVideoAllocation(), activeRIDs: ["100"], codec: .h264
        )
        let expected = Data([0, 0, 0, 1, 0x65]
            + (0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 7) })
        try await sender.sendVideoFrame(encodedFrame: expected)

        let receiver = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: NativeMediaDatagramDouble()
        )
        _ = try await receiver.install(makeCapability(generation: 96, daveProtocolVersion: 1))
        let decoded = try await receiver.receiveH264AccessUnit(
            packets: await wire.sentPackets,
            senderID: 42
        )
        #expect(decoded == expected)
        #expect(await daveSession.lastUnprotectedMediaType == .video)
        #expect(await daveSession.lastUnprotectedSenderID == 42)
        #expect(await receiver.receiveDiagnostics().acceptedVideoAccessUnits == 1)

        var tampered = await wire.sentPackets
        tampered[0][tampered[0].count - 5] ^= 1
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receiveTransportAuthenticationFailed) {
            _ = try await receiver.receiveH264AccessUnit(packets: tampered, senderID: 42)
        }
    }

    @Test("H264 receive rejects an access-unit packet list above the bounded fragment budget")
    func h264ReceiveRejectsUnboundedPacketList() async throws {
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let receiver = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: NativeMediaDatagramDouble()
        )
        _ = try await receiver.install(makeCapability(generation: 97, daveProtocolVersion: 1))
        let packets = Array(
            repeating: [UInt8](),
            count: DiscordVoiceVideoPacketizer.defaultMaximumFragmentsPerFrame + 1
        )
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receivePacketMalformed) {
            _ = try await receiver.receiveH264AccessUnit(packets: packets, senderID: 42)
        }
    }

    @Test("H264 receive rejects a completed access unit followed by an unmarked trailing packet")
    func h264ReceiveRejectsPacketsAfterTheAccessUnitMarker() async throws {
        let wire = NativeMediaDatagramDouble()
        let daveSession = NativeDAVEMediaSessionDouble(protocolVersion: 1, isMediaReady: true)
        let sender = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: wire,
            makeRTPClockSeed: { (700, 90_000) }
        )
        await sender.attachVideoAnnouncementSignal { _ in }
        _ = try await sender.install(makeCapability(generation: 902, daveProtocolVersion: 1))
        try await sender.installVideoSource(
            allocation: try makeVideoAllocation(), activeRIDs: ["100"], codec: .h264
        )
        try await sender.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 31))
        try await sender.sendVideoFrame(encodedFrame: fixedEncodedVideoFrame(seed: 32))

        let opener = try receiverTransport()
        let sealer = try senderTransport()
        let codec = try DiscordVoiceRTPCodec()
        var malformed: [[UInt8]] = []
        for (index, packet) in (await wire.sentPackets).enumerated() {
            let opened = try await opener.open(packet)
            let original = try codec.decodeHeader(from: opened)
            let layout = try codec.plaintextLayout(in: opened)
            let header = try DiscordVoiceRTPHeader(
                marker: index == 0,
                payloadType: original.payloadType,
                sequence: UInt16(800 + index),
                timestamp: 120_000,
                ssrc: original.ssrc
            )
            malformed.append(try await sealer.seal(
                try codec.encode(header) + Array(opened[layout.payloadRange])
            ))
        }

        let receiver = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: NativeMediaDatagramDouble()
        )
        _ = try await receiver.install(makeCapability(generation: 903, daveProtocolVersion: 1))
        await #expect(throws: DiscordVoiceNativeMediaPlaneError.receivePacketMalformed) {
            _ = try await receiver.receiveH264AccessUnit(packets: malformed, senderID: 42)
        }
        #expect(await daveSession.unprotectCallCount == 0)
    }

    private func fixedEncodedVideoFrame(seed: Int) -> Data {
        Data([0, 0, 0, 1, 0x65] + (0..<320).map { index in
            UInt8(truncatingIfNeeded: (index &* 31) &+ (seed &* 97) &+ 5)
        })
    }

    private func makeVideoAllocation(
        audioSSRC: UInt32 = 0x1111_1111,
        videoSSRC: UInt32 = 0x2222_2222
    ) throws -> VoiceGatewayV8VideoSSRCAllocation {
        try VoiceGatewayV8VideoSSRCAllocation(
            audioSSRC: audioSSRC,
            streams: [
                try VoiceGatewayV8Stream(
                    type: "video",
                    rid: "100",
                    quality: 100,
                    ssrc: videoSSRC,
                    rtxSSRC: videoSSRC &+ 1
                )
            ]
        )

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
    private(set) var unprotectCallCount = 0
    private(set) var lastUnprotectInputFrame: Data?
    private(set) var lastUnprotectOutputFrame: Data?
    private(set) var lastUnprotectedMediaType: NativeDAVEMediaType?
    private(set) var lastUnprotectedSenderID: UInt64?
    private var forcedUnprotectFailure: (any Error)?

    init(protocolVersion: UInt16, isMediaReady: Bool) {
        self.protocolVersion = protocolVersion
        self.isMediaReady = isMediaReady
    }

    func failNextProtect(with error: any Error) {
        forcedFailure = error
    }

    func failNextUnprotect(with error: any Error) {
        forcedUnprotectFailure = error
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
        let transformed: Data
        if mediaType == .video, codec == .h264,
           let units = try? DiscordVoiceH264Packetizer.nalUnits(in: Array(frame)) {
            // Model libdave's H.264-aware transform: keep Annex-B framing and
            // every NAL header parseable while changing the encoded body.
            // This stays deterministic/non-identity without pretending the
            // fixture can manufacture genuine MLS ciphertext.
            var bytes = Data()
            for unit in units {
                bytes.append(contentsOf: [0, 0, 0, 1])
                bytes.append(unit[0])
                bytes.append(contentsOf: unit.dropFirst().map { $0 ^ 0xff })
            }
            transformed = bytes
        } else {
            transformed = Data(frame.map { $0 ^ 0xff })
        }
        lastProtectedFrame = transformed
        return transformed
    }

    /// The exact inverse of `protect` above: XOR by 0xff is self-inverse, so a
    /// receive path that skipped this call (a plaintext passthrough) hands the
    /// decoder bytes that are provably not the sender's Opus payload.
    func unprotect(
        _ frame: Data,
        mediaType: NativeDAVEMediaType,
        senderID: UInt64
    ) throws -> Data {
        unprotectCallCount += 1
        lastUnprotectInputFrame = frame
        lastUnprotectedMediaType = mediaType
        lastUnprotectedSenderID = senderID
        if let forcedUnprotectFailure {
            throw forcedUnprotectFailure
        }
        let transformed: Data
        if mediaType == .video,
           let units = try? DiscordVoiceH264Packetizer.nalUnits(in: Array(frame)) {
            var bytes = Data()
            for unit in units {
                bytes.append(contentsOf: [0, 0, 0, 1])
                bytes.append(unit[0])
                bytes.append(contentsOf: unit.dropFirst().map { $0 ^ 0xff })
            }
            transformed = bytes
        } else {
            transformed = Data(frame.map { $0 ^ 0xff })
        }
        lastUnprotectOutputFrame = transformed
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

    func markShouldSucceed() {
        shouldFail = false
    }

    func signal() throws {
        callCount += 1
        if shouldFail {
            throw TestSpeakingFailure.injected
        }
    }
}

/// A Speaking signal that suspends its first caller until the test releases
/// it. Once released, later calls complete immediately with the same latched
/// outcome, so a frame that (racily) re-attempts after a released failure
/// still fails deterministically instead of hanging.
private actor SuspendableSpeakingSignal {
    private(set) var callCount = 0
    private var released = false
    private var failWhenReleased = false
    private var signalStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func signal() async throws {
        callCount += 1
        let startWaiters = signalStartWaiters
        signalStartWaiters.removeAll(keepingCapacity: false)
        for waiter in startWaiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        if failWhenReleased {
            throw TestSpeakingFailure.injected
        }
        try Task.checkCancellation()
    }

    func waitUntilSignalStarted() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { signalStartWaiters.append($0) }
    }

    func release(failing: Bool) {
        released = true
        failWhenReleased = failing
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

/// A datagram transport whose send suspends until released, honoring task
/// cancellation, so tests can pin what `reset()` does to an in-flight send.
private actor SuspendableDatagramDouble: DiscordVoiceMediaDatagramTransport {
    private var watchdog: Task<Void, Never>?
    private(set) var deliveredPackets: [[UInt8]] = []
    private var released = false
    private var sendStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendStarted = false
    private var sendContinuation: CheckedContinuation<Void, any Error>?
    private var cancelled = false

    deinit { watchdog?.cancel() }

    func sendProtectedPacket(_ bytes: [UInt8]) async throws {
        sendStarted = true
        let waiters = sendStartWaiters
        sendStartWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        try await withTaskCancellationHandler {
            try await waitUntilReleased()
        } onCancel: {
            Task { await self.cancelSend() }
        }
        deliveredPackets.append(bytes)
    }

    func receiveProtectedPacket() async throws -> [UInt8] {
        throw CancellationError()
    }

    func disconnect() async {}

    func waitUntilSendStarted() async {
        if watchdog == nil {
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await self?.expire()
            }
        }
        guard !sendStarted else { return }
        await withCheckedContinuation { sendStartWaiters.append($0) }
    }

    func release() {
        watchdog?.cancel()
        released = true
        sendContinuation?.resume()
        sendContinuation = nil
    }

    private func cancelSend() {
        watchdog?.cancel()
        cancelled = true
        sendContinuation?.resume(throwing: CancellationError())
        sendContinuation = nil
    }

    private func waitUntilReleased() async throws {
        try Task.checkCancellation()
        if !released {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sendContinuation = continuation
                }
            }
        }
        try Task.checkCancellation()
    }

    private func expire() {
        Issue.record("Timed out waiting for native datagram test gate; releasing all barriers")
        sendStarted = true
        for waiter in sendStartWaiters { waiter.resume() }
        sendStartWaiters.removeAll()
        cancelSend()
    }
}

private enum TestSpeakingFailure: Error, Equatable {
    case injected
}

private actor VideoAnnouncementRecorder {
    private(set) var callCount = 0
    private(set) var announcements: [VoiceGatewayV8Video] = []
    private var shouldFail = false

    func markShouldFail() {
        shouldFail = true
    }

    func signal(_ announcement: VoiceGatewayV8Video) throws {
        callCount += 1
        announcements.append(announcement)
        if shouldFail {
            throw TestVideoAnnouncementFailure.injected
        }
    }
}

private enum TestVideoAnnouncementFailure: Error, Equatable {
    case injected
}

/// An Opcode 12 announcement callback that suspends its first caller until the
/// test releases it, recording the exact announcement it was handed. Modeled on
/// `SuspendableSpeakingSignal`; once released, later calls complete
/// immediately so a re-attempting frame cannot hang the suite.
private actor SuspendableVideoAnnouncementSignal {
    private(set) var callCount = 0
    private(set) var announcements: [VoiceGatewayV8Video] = []
    private var released = false
    private var signalStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func signal(_ announcement: VoiceGatewayV8Video) async throws {
        callCount += 1
        announcements.append(announcement)
        let startWaiters = signalStartWaiters
        signalStartWaiters.removeAll(keepingCapacity: false)
        for waiter in startWaiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitUntilSignalStarted() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { signalStartWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
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

/// Holds every send-time provider lookup until the requested number of
/// overlapping sends has entered the media plane. The install-time lookup is
/// returned immediately. This turns actor reentrancy at the RTP-clock boundary
/// into a deterministic regression test instead of a scheduler-dependent one.
private actor ConcurrentSendPathGate {
    private let session: any DiscordVoiceNativeDAVEMediaSession
    private var callCount = 0
    private var sendRequestCount = 0
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(session: any DiscordVoiceNativeDAVEMediaSession) {
        self.session = session
    }

    func provide() async -> (any DiscordVoiceNativeDAVEMediaSession)? {
        callCount += 1
        guard callCount > 1 else { return session }
        sendRequestCount += 1
        let ready = requestWaiters.filter { sendRequestCount >= $0.0 }
        requestWaiters.removeAll { sendRequestCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return session
    }

    func waitUntilSendRequests(_ count: Int) async {
        guard sendRequestCount < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
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
