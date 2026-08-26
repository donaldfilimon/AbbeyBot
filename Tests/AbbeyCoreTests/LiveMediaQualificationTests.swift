import Foundation
import Testing
@testable import AbbeyCore

@Suite("Live media qualification consent")
struct LiveMediaQualificationTests {
    @Test func canaryRequiresCurrentUnanimousConsentManagerH264AndDAVE1() async throws {
        let coordinator = LiveMediaQualificationCoordinator(environment: [
            "ABBEY_MEDIA_QUALIFICATION_CANARY": "1"
        ])
        let participants: Set<String> = [
            LiveMediaQualificationCoordinator.participantDigest("one"),
            LiveMediaQualificationCoordinator.participantDigest("two"),
        ]
        let epoch = try await coordinator.open(
            guildID: "guild-a",
            guildAuthorizationClass: "owner-authorized-canary",
            participantDigests: participants,
            participantSetComplete: true,
            allCurrentParticipantsConsented: true,
            managerAuthorized: true,
            capabilities: [.audioSend, .audioReceive, .cameraSend, .cameraReceive],
            daveProtocolVersion: 1,
            codec: "H264"
        )
        #expect(epoch.participantCount == 2)
        #expect(epoch.hash.count == 64)
        let lease = try await coordinator.qualificationLease()
        #expect(lease.qualifies(guildID: "guild-a"))
        #expect(!lease.qualifies(guildID: "guild-b"))
        #expect(await coordinator.snapshot().epoch?.hash == epoch.hash)

        await #expect(throws: LiveMediaQualificationError.epochMismatch) {
            try await coordinator.revalidate(
                expectedEpochHash: epoch.hash,
                participantDigests: [LiveMediaQualificationCoordinator.participantDigest("one")],
                participantSetComplete: true,
                managerAuthorized: true,
                allCurrentParticipantsConsented: true
            )
        }
        #expect(await coordinator.snapshot().epoch == nil)
        #expect(await coordinator.snapshot().lastCloseReason == .participantChanged)
        #expect(!lease.qualifies(guildID: "guild-a"))
    }

    @Test func everyAuthorityOrProtocolGapFailsClosed() async {
        let disabled = LiveMediaQualificationCoordinator(environment: [:])
        await #expect(throws: LiveMediaQualificationError.canaryDisabled) {
            _ = try await disabled.open(
                guildID: "guild-a",
                guildAuthorizationClass: "owner",
                participantDigests: [LiveMediaQualificationCoordinator.participantDigest("one")],
                participantSetComplete: true,
                allCurrentParticipantsConsented: true,
                managerAuthorized: true,
                capabilities: [.audioSend],
                daveProtocolVersion: 1,
                codec: "H264"
            )
        }

        let enabled = LiveMediaQualificationCoordinator(environment: [
            "ABBEY_MEDIA_QUALIFICATION_CANARY": "true"
        ])
        await #expect(throws: LiveMediaQualificationError.unsupportedCodec) {
            _ = try await enabled.open(
                guildID: "guild-a",
                guildAuthorizationClass: "owner",
                participantDigests: [LiveMediaQualificationCoordinator.participantDigest("one")],
                participantSetComplete: true,
                allCurrentParticipantsConsented: true,
                managerAuthorized: true,
                capabilities: [.audioSend],
                daveProtocolVersion: 1,
                codec: "VP8"
            )
        }
        await #expect(throws: LiveMediaQualificationError.unsupportedDAVEVersion) {
            _ = try await enabled.open(
                guildID: "guild-a",
                guildAuthorizationClass: "owner",
                participantDigests: [LiveMediaQualificationCoordinator.participantDigest("one")],
                participantSetComplete: true,
                allCurrentParticipantsConsented: true,
                managerAuthorized: true,
                capabilities: [.audioSend],
                daveProtocolVersion: 0,
                codec: "H264"
            )
        }
    }

    @Test func controllerConsentGateStopsEveryLaneAndClearsQueues() async throws {
        let controller = try DiscordVoiceController(
            bridge: QualificationBridge(),
            factory: QualificationFactory(),
            configuration: DiscordVoiceControllerConfiguration(requiresConsentEpoch: true)
        )
        _ = await controller.join(guildID: "g", channelID: "c")
        #expect(!(await controller.setMicrophoneEnabled(true)).microphoneEnabled)
        #expect(!(await controller.setCameraEnabled(true)).cameraEnabled)

        _ = try await controller.installConsentEpoch(hash: String(repeating: "a", count: 64))
        #expect((await controller.setMicrophoneEnabled(true)).microphoneEnabled)
        #expect((await controller.setCameraEnabled(true)).cameraEnabled)

        // A replacement Voice Gateway/UDP connection is outside the consent
        // epoch that authorized the old connection. Reconnect must therefore
        // close every lane and require an explicitly installed fresh epoch.
        let reconnected = await controller.reconnect()
        #expect(!reconnected.microphoneEnabled)
        #expect(!reconnected.cameraEnabled)
        #expect(!(await controller.setMicrophoneEnabled(true)).microphoneEnabled)

        _ = try await controller.installConsentEpoch(hash: String(repeating: "b", count: 64))
        #expect((await controller.setCameraEnabled(true)).cameraEnabled)
        let closed = await controller.closeConsentEpoch()
        #expect(!closed.microphoneEnabled)
        #expect(!closed.cameraEnabled)
        #expect(!closed.screenShareEnabled)
        #expect(!closed.receiveActive)
        #expect(closed.queuedAudioFrames == 0)
        #expect(closed.queuedVideoFrames == 0)
    }

    @Test func exactGuildLeasePromotesOnlyOneQualifiedSessionConstruction() async throws {
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
        let controller = try DiscordVoiceController(
            bridge: QualificationBridge(),
            factory: QualificationLeaseFactory(),
            configuration: DiscordVoiceControllerConfiguration(requiresConsentEpoch: true)
        )
        let refused = await controller.join(
            guildID: "different-guild",
            channelID: "c",
            qualificationLease: lease
        )
        #expect(refused.phase == .failed)
        #expect(refused.failure == .mediaUnavailable)
        #expect(!refused.mediaAdapterAvailable)

        let ready = await controller.join(
            guildID: "g",
            channelID: "c",
            qualificationLease: lease
        )
        #expect(ready.phase == .readyMuted)
        #expect(ready.mediaAdapterAvailable)
        #expect(!(await controller.setCameraEnabled(true)).cameraEnabled)

        let replayed = await controller.join(
            guildID: "g",
            channelID: "c",
            qualificationLease: lease
        )
        #expect(replayed.phase == .failed)
        #expect(replayed.failure == .mediaUnavailable)
    }

    @Test func anOpenEpochCannotBeSilentlyReplaced() async throws {
        let coordinator = LiveMediaQualificationCoordinator(environment: [
            "ABBEY_MEDIA_QUALIFICATION_CANARY": "1"
        ])
        let participants: Set<String> = [
            LiveMediaQualificationCoordinator.participantDigest("one")
        ]
        _ = try await coordinator.open(
            guildID: "g",
            guildAuthorizationClass: "owner",
            participantDigests: participants,
            participantSetComplete: true,
            allCurrentParticipantsConsented: true,
            managerAuthorized: true,
            capabilities: [.audioSend],
            daveProtocolVersion: 1,
            codec: "H264"
        )

        await #expect(throws: LiveMediaQualificationError.epochAlreadyOpen) {
            _ = try await coordinator.open(
                guildID: "g",
                guildAuthorizationClass: "owner",
                participantDigests: participants,
                participantSetComplete: true,
                allCurrentParticipantsConsented: true,
                managerAuthorized: true,
                capabilities: [.audioSend],
                daveProtocolVersion: 1,
                codec: "H264"
            )
        }
    }

    @Test func incompleteParticipantObservationAndUnsafeAuthorityLabelFailClosed() async throws {
        let coordinator = LiveMediaQualificationCoordinator(environment: [
            "ABBEY_MEDIA_QUALIFICATION_CANARY": "1"
        ])
        let participants: Set<String> = [
            LiveMediaQualificationCoordinator.participantDigest("one")
        ]
        await #expect(throws: LiveMediaQualificationError.participantSetIncomplete) {
            _ = try await coordinator.open(
                guildID: "g",
                guildAuthorizationClass: "owner",
                participantDigests: participants,
                participantSetComplete: false,
                allCurrentParticipantsConsented: true,
                managerAuthorized: true,
                capabilities: [.audioSend],
                daveProtocolVersion: 1,
                codec: "H264"
            )
        }
        await #expect(throws: LiveMediaQualificationError.invalidGuildAuthorizationClass) {
            _ = try await coordinator.open(
                guildID: "g",
                guildAuthorizationClass: "owner authorized",
                participantDigests: participants,
                participantSetComplete: true,
                allCurrentParticipantsConsented: true,
                managerAuthorized: true,
                capabilities: [.audioSend],
                daveProtocolVersion: 1,
                codec: "H264"
            )
        }

        let epoch = try await coordinator.open(
            guildID: "g",
            guildAuthorizationClass: "owner",
            participantDigests: participants,
            participantSetComplete: true,
            allCurrentParticipantsConsented: true,
            managerAuthorized: true,
            capabilities: [.audioSend],
            daveProtocolVersion: 1,
            codec: "H264"
        )
        await #expect(throws: LiveMediaQualificationError.participantSetIncomplete) {
            try await coordinator.revalidate(
                expectedEpochHash: epoch.hash,
                participantDigests: participants,
                participantSetComplete: false,
                managerAuthorized: true,
                allCurrentParticipantsConsented: true
            )
        }
        #expect(await coordinator.snapshot().lastCloseReason == .participantUnidentified)
    }

    @Test func epochsAreUniqueAndStaleRevalidationCannotCloseAReplacement() async throws {
        let coordinator = LiveMediaQualificationCoordinator(environment: [
            "ABBEY_MEDIA_QUALIFICATION_CANARY": "1"
        ])
        let participants = Set([
            LiveMediaQualificationCoordinator.participantDigest("one")
        ])
        let fixedTime = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await coordinator.open(
            guildID: "g",
            guildAuthorizationClass: "owner",
            participantDigests: participants,
            participantSetComplete: true,
            allCurrentParticipantsConsented: true,
            managerAuthorized: true,
            capabilities: [.audioSend],
            daveProtocolVersion: 1,
            codec: "H264",
            now: fixedTime
        )
        await coordinator.close(.operatorStop)
        let second = try await coordinator.open(
            guildID: "g",
            guildAuthorizationClass: "owner",
            participantDigests: participants,
            participantSetComplete: true,
            allCurrentParticipantsConsented: true,
            managerAuthorized: true,
            capabilities: [.audioSend],
            daveProtocolVersion: 1,
            codec: "H264",
            now: fixedTime
        )
        #expect(first.hash != second.hash)
        await #expect(throws: LiveMediaQualificationError.epochMismatch) {
            try await coordinator.revalidate(
                expectedEpochHash: first.hash,
                participantDigests: participants,
                participantSetComplete: true,
                managerAuthorized: true,
                allCurrentParticipantsConsented: true
            )
        }
        #expect(await coordinator.snapshot().epoch?.hash == second.hash)
    }

    @Test func promotionReceiptRequiresEveryWitnessedOutcomeAndImmutableRevision() throws {
        var outcomes = Dictionary(
            uniqueKeysWithValues: LiveMediaQualificationReceipt.requiredPromotionOutcomes.map {
                ($0, true)
            }
        )
        var receipt = LiveMediaQualificationReceipt(
            candidateCommit: String(repeating: "a", count: 40),
            dependencyRevisions: ["libdave": String(repeating: "b", count: 40)],
            guildAuthorizationClass: "discord-manager-authorized-canary",
            consentEpochHash: String(repeating: "c", count: 64),
            daveProtocolVersion: 1,
            selectedCodec: "H264",
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            outcomes: outcomes
        )
        #expect(throws: Never.self) { _ = try receipt.validatedForPromotion() }

        outcomes["cameraReceive"] = false
        receipt.outcomes = outcomes
        #expect(throws: LiveMediaQualificationError.invalidQualificationReceipt) {
            _ = try receipt.validatedForPromotion()
        }
        receipt.candidateCommit = "main"
        #expect(throws: LiveMediaQualificationError.invalidQualificationReceipt) {
            _ = try receipt.validatedForPromotion(requiredOutcomes: [])
        }

        var weakened = receipt
        weakened.candidateCommit = String(repeating: "a", count: 40)
        weakened.outcomes = [:]
        #expect(throws: LiveMediaQualificationError.invalidQualificationReceipt) {
            _ = try weakened.validatedForPromotion(requiredOutcomes: [])
        }

        var falseWitness = LiveMediaQualificationReceipt(
            candidateCommit: String(repeating: "a", count: 40),
            dependencyRevisions: ["libdave": String(repeating: "b", count: 40)],
            guildAuthorizationClass: "discord-manager-authorized-canary",
            consentEpochHash: String(repeating: "c", count: 64),
            daveProtocolVersion: 1,
            selectedCodec: "H264",
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            outcomes: Dictionary(
                uniqueKeysWithValues: LiveMediaQualificationReceipt.requiredPromotionOutcomes.map {
                    ($0, true)
                }
            )
        )
        falseWitness.outcomes["additionalWitness"] = false
        #expect(throws: LiveMediaQualificationError.invalidQualificationReceipt) {
            _ = try falseWitness.validatedForPromotion()
        }
    }
}

private struct QualificationBridge: DiscordVoiceGatewayPairBridge {
    func requestGatewayState(guildID: String, channelID: String) async throws {}
    func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair {
        .init(endpoint: "localhost", token: "t", sessionID: "s", serverID: "g", channelID: "c", userID: "u")
    }
    func leaveVoice(guildID: String) async {}
}

private struct QualificationFactory: DiscordVoiceSessionFactory {
    var mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability { .fullyWired }
    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient { QualificationGateway() }
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession { QualificationUDP() }
}

private struct QualificationLeaseFactory: DiscordVoiceSessionFactory {
    var mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability { .locallyComposed }
    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient { QualificationGateway() }
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession { QualificationUDP() }
    func makeSessionComponents(
        qualificationLease: DiscordVoiceQualificationLease?
    ) -> DiscordVoiceSessionComponents {
        .init(
            gateway: QualificationGateway(),
            udp: QualificationUDP(),
            mediaAdapterAvailability: qualificationLease == nil ? .locallyComposed : .fullyWired
        )
    }
}

private actor QualificationGateway: DiscordVoiceGatewaySessionClient {
    func connect(using pair: DiscordVoiceGatewayPair) async throws -> DiscordVoiceGatewayTransportReady {
        .init(address: "127.0.0.1", port: 9, ssrc: 1, encryptionModes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue])
    }
    func selectTransport(_ endpoint: DiscordVoiceDiscoveredEndpoint) async throws {}
    func negotiateDAVEAndMedia() async throws -> DiscordVoiceMediaCapabilities {
        .init(dave: true, aead: true, opus: true)
    }
    func disconnect() async {}
}

private actor QualificationUDP: DiscordVoiceUDPDiscoverySession {
    func discoverEndpoint(for ready: DiscordVoiceGatewayTransportReady) async throws -> DiscordVoiceDiscoveredEndpoint {
        .init(address: "127.0.0.1", port: 9)
    }
    func disconnect() async {}
}
