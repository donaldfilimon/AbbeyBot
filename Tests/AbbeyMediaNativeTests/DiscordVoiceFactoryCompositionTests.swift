import AbbeyCore
import Foundation
import Testing
@testable import AbbeyMediaNative

/// Minimal playback boundary. The production sink lives in AbbeyBotApp, which
/// this target cannot see, but the factory only needs `any
/// DiscordVoicePlaybackSink` — so a stub proves the composition logic without
/// dragging the app in.
private struct StubPlaybackSink: DiscordVoicePlaybackSink {
    func play(pcm: [Int16]) async throws {}
}

private struct StubCaptureSource: DiscordVoiceCaptureSource {
    func startCapture() async throws -> AsyncStream<[Int16]> {
        AsyncStream { $0.finish() }
    }
    func stopCapture() async {}
}

@Suite("Native factory audio composition")
struct DiscordVoiceFactoryCompositionTests {
    /// The regression this pins: `mediaAdapterAvailability` was hardcoded
    /// `.unavailable`, so `join()` never set `acceptsFrames` and
    /// `setReceiveEnabled(true)` could not succeed no matter how complete the
    /// receive path was. Audio was unreachable by construction.
    @Test("both directions present report locallyComposed and build a receive loop")
    func bothDirectionsComposeLocally() async throws {
        let factory = DiscordVoiceNativeControlSessionFactory(
            captureSource: StubCaptureSource(),
            playbackSink: StubPlaybackSink()
        )
        #expect(factory.mediaAdapterAvailability == .locallyComposed)
        #expect(factory.mediaAdapterAvailability.permitsLocalMedia)
        // Local composition must NOT imply the wire-facing DAVE claim.
        #expect(factory.mediaAdapterAvailability != .fullyWired)

        let components = factory.makeSessionComponents()
        #expect(components.receiveLoop != nil)
        #expect(components.captureLoop != nil)
    }

    @Test("a missing direction stays unavailable and builds no receive loop")
    func missingDirectionStaysUnavailable() async throws {
        let captureOnly = DiscordVoiceNativeControlSessionFactory(
            captureSource: StubCaptureSource()
        )
        #expect(captureOnly.mediaAdapterAvailability == .unavailable)
        #expect(captureOnly.makeSessionComponents().receiveLoop == nil)

        let playbackOnly = DiscordVoiceNativeControlSessionFactory(
            playbackSink: StubPlaybackSink()
        )
        #expect(playbackOnly.mediaAdapterAvailability == .unavailable)
        #expect(playbackOnly.makeSessionComponents().captureLoop == nil)

        let neither = DiscordVoiceNativeControlSessionFactory()
        #expect(!neither.mediaAdapterAvailability.permitsLocalMedia)
    }

    /// Advertising DAVE is a claim to Discord, not a local capability, so it
    /// must not ride along with local composition.
    @Test("locally composed still advertises DAVE version 0")
    func localCompositionDoesNotAdvertiseDAVE() async throws {
        #expect(
            DiscordVoiceNativeControlSessionFactory.advertisedDAVEProtocolVersion(
                for: .locallyComposed
            ) == 0
        )
        #expect(
            DiscordVoiceNativeControlSessionFactory.advertisedDAVEProtocolVersion(
                for: .unavailable
            ) == 0
        )
    }

    @Test("only an exact content-free qualification lease promotes one component bundle")
    func leasePromotesOnlyTheConstructedCanarySession() async throws {
        let factory = DiscordVoiceNativeControlSessionFactory(
            captureSource: StubCaptureSource(),
            playbackSink: StubPlaybackSink()
        )
        let coordinator = LiveMediaQualificationCoordinator(environment: [
            "ABBEY_MEDIA_QUALIFICATION_CANARY": "1"
        ])
        _ = try await coordinator.open(
            guildID: "g",
            guildAuthorizationClass: "owner",
            participantDigests: [LiveMediaQualificationCoordinator.participantDigest("one")],
            participantSetComplete: true,
            allCurrentParticipantsConsented: true,
            managerAuthorized: true,
            capabilities: [.audioSend, .audioReceive],
            daveProtocolVersion: 1,
            codec: "H264"
        )
        let lease = try await coordinator.qualificationLease()
        #expect(factory.makeSessionComponents().mediaAdapterAvailability == .locallyComposed)
        #expect(lease.admit(guildID: "g"))
        #expect(
            factory.makeSessionComponents(qualificationLease: lease).mediaAdapterAvailability
                == .fullyWired
        )
        #expect(
            factory.makeSessionComponents(qualificationLease: lease).mediaAdapterAvailability
                == .locallyComposed
        )
    }
}
