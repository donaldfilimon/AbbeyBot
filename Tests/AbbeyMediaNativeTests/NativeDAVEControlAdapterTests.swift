import AbbeyCore
import Foundation
import Testing
@testable import AbbeyMediaNative

@Suite("Native DAVE control adapter")
struct NativeDAVEControlAdapterTests {
    @Test("native factory creates one fail-closed component bundle per join")
    func nativeFactoryBundle() {
        let factory = DiscordVoiceNativeControlSessionFactory()
        let components = factory.makeSessionComponents()

        #expect(factory.mediaAdapterAvailability == .unavailable)
        #expect(components.gateway is DiscordVoiceGatewaySession)
        #expect(components.udp is DiscordVoiceUDPSessionAdapter)
    }

    @Test("nonzero DAVE is advertised only when media adapters are fully wired")
    func daveAdvertisementGatedOnMediaAvailability() {
        #expect(
            DiscordVoiceNativeControlSessionFactory.advertisedDAVEProtocolVersion(
                for: .unavailable
            ) == 0
        )
        #expect(
            DiscordVoiceNativeControlSessionFactory.advertisedDAVEProtocolVersion(
                for: .fullyWired
            ) == Int(NativeMediaVersions.maximumDAVEProtocolVersion)
        )
        #expect(NativeMediaVersions.maximumDAVEProtocolVersion > 0)
    }

    @Test("initial bootstrap creates one shared native session and reset destroys access")
    func initialBootstrapAndReset() async throws {
        let adapter = NativeDAVEControlAdapter()
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 100, selfUserID: 200)

        let outbound = try await adapter.beginSession(
            context: context,
            protocolVersion: 1
        )
        #expect(outbound.count == 1)
        guard case .keyPackage(let keyPackage) = outbound.first else {
            Issue.record("Expected one initial DAVE Key Package")
            return
        }
        #expect(keyPackage.count > 0)
        let sharedSession = await adapter.mediaSession()
        #expect(sharedSession != nil)
        #expect(await sharedSession?.protocolVersion == 1)

        await adapter.reset()
        #expect(await adapter.mediaSession() == nil)

        let diagnostics = "\(adapter) \(String(reflecting: adapter))"
        #expect(!diagnostics.contains("100"))
        #expect(!diagnostics.contains("200"))
        #expect(diagnostics.contains("<redacted>"))
    }

    @Test("downgrade remains staged until Execute Transition then drops native MLS")
    func stagedDowngrade() async throws {
        let adapter = NativeDAVEControlAdapter()
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 300, selfUserID: 400)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)

        let prepare = VoiceGatewayDAVEPrepareTransition(
            protocolVersion: 0,
            transitionID: 9
        )
        let ready = try await adapter.handle(
            VoiceGatewayDAVEInboundFrame(
                sequence: nil,
                message: .prepareTransition(prepare)
            ),
            event: .transitionPrepared(9)
        )
        #expect(ready == [
            .transitionReady(VoiceGatewayDAVETransitionReady(transitionID: 9))
        ])
        #expect(await adapter.mediaSession() != nil)

        let execute = VoiceGatewayDAVEExecuteTransition(transitionID: 9)
        let outbound = try await adapter.handle(
            VoiceGatewayDAVEInboundFrame(
                sequence: nil,
                message: .executeTransition(execute)
            ),
            event: .transitionExecuted(9)
        )
        #expect(outbound.isEmpty)
        #expect(await adapter.mediaSession() == nil)
    }

    @Test("Prepare Epoch leaves the active media identity and readiness unchanged")
    func prepareEpochDoesNotPublishPendingSession() async throws {
        let adapter = NativeDAVEControlAdapter()
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 500, selfUserID: 600)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        let initialSession = try #require(await adapter.mediaSession())
        let initialReadiness = await initialSession.isMediaReady

        let epoch = VoiceGatewayDAVEPrepareEpoch(
            protocolVersion: 1,
            transitionID: 10,
            epoch: 2
        )
        let epochMessages = try await adapter.handle(
            VoiceGatewayDAVEInboundFrame(
                sequence: nil,
                message: .prepareEpoch(epoch)
            ),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 10,
                epoch: 2
            ))
        )
        #expect(epochMessages.map(\.opcode) == [.keyPackage])
        let preExecuteSession = try #require(await adapter.mediaSession())
        #expect(initialSession === preExecuteSession)
        #expect(await preExecuteSession.isMediaReady == initialReadiness)

        await #expect(throws: NativeDAVEControlAdapterError.transitionProtocolUnavailable) {
            _ = try await adapter.handle(
                executeFrame(transitionID: 10),
                event: .transitionExecuted(10)
            )
        }
        #expect(await adapter.mediaSession() === initialSession)
    }

    @Test("a ready pending epoch is promoted only by its Execute Transition")
    func readyPendingEpochPromotion() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(initiallyReady: true, processing: .succeed),
            .init(initiallyReady: false, processing: .succeed),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 700, selfUserID: 701)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        let active = try #require(factory.session(at: 0))

        _ = try await adapter.handle(
            prepareEpochFrame(transitionID: 20, epoch: 2),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 20,
                epoch: 2
            ))
        )
        let pending = try #require(factory.session(at: 1))
        #expect(await pending.isMediaReady == false)

        _ = try await adapter.handle(proposalsFrame(), event: .mlsPayloadReceived(.proposals))
        #expect(await active.proposalCallCount == 0)
        #expect(await pending.proposalCallCount == 1)

        let ready = try await adapter.handle(
            welcomeFrame(transitionID: 20),
            event: .requiresMLSProcessing(20)
        )
        #expect(ready == [
            .transitionReady(VoiceGatewayDAVETransitionReady(transitionID: 20))
        ])
        #expect(await pending.isMediaReady)

        // Successful MLS processing alone must not publish the pending actor.
        _ = try await adapter.handle(proposalsFrame(), event: .mlsPayloadReceived(.proposals))
        #expect(await active.proposalCallCount == 0)
        #expect(await pending.proposalCallCount == 2)

        _ = try await adapter.handle(
            executeFrame(transitionID: 20),
            event: .transitionExecuted(20)
        )
        _ = try await adapter.handle(proposalsFrame(), event: .mlsPayloadReceived(.proposals))
        #expect(await active.proposalCallCount == 0)
        #expect(await pending.proposalCallCount == 3)
    }

    @Test("overlapping and stale IDs cannot replace or execute a pending downgrade")
    func overlappingStaleAndDuplicateExecute() async throws {
        let adapter = NativeDAVEControlAdapter()
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 800, selfUserID: 801)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        let active = try #require(await adapter.mediaSession())

        _ = try await adapter.handle(
            downgradeFrame(transitionID: 30),
            event: .transitionPrepared(30)
        )
        await #expect(throws: NativeDAVEControlAdapterError.transitionProtocolUnavailable) {
            _ = try await adapter.handle(
                prepareEpochFrame(transitionID: 31, epoch: 3),
                event: .epochAnnounced(.init(
                    protocolVersion: 1,
                    transitionID: 31,
                    epoch: 3
                ))
            )
        }
        await #expect(throws: NativeDAVEControlAdapterError.transitionProtocolUnavailable) {
            _ = try await adapter.handle(
                executeFrame(transitionID: 31),
                event: .transitionExecuted(31)
            )
        }
        #expect(await adapter.mediaSession() === active)

        _ = try await adapter.handle(
            executeFrame(transitionID: 30),
            event: .transitionExecuted(30)
        )
        #expect(await adapter.mediaSession() == nil)
        await #expect(throws: NativeDAVEControlAdapterError.transitionProtocolUnavailable) {
            _ = try await adapter.handle(
                executeFrame(transitionID: 30),
                event: .transitionExecuted(30)
            )
        }
    }

    @Test("invalid native MLS recovery replaces poisoned pending state but is not executable")
    func recoveryRetainsNotReadyReplacement() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(initiallyReady: true, processing: .succeed),
            .init(initiallyReady: false, processing: .failNative(.daveCommitFailed)),
            .init(initiallyReady: false, processing: .succeed),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 900, selfUserID: 901)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        let active = try #require(factory.session(at: 0))

        _ = try await adapter.handle(
            prepareEpochFrame(transitionID: 40, epoch: 4),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 40,
                epoch: 4
            ))
        )
        let recovery = try await adapter.handle(
            commitFrame(transitionID: 40),
            event: .requiresMLSProcessing(40)
        )
        #expect(recovery.map(\.opcode) == [.invalidCommitWelcome, .keyPackage])
        #expect(factory.sessionCount == 3)
        let replacement = try #require(factory.session(at: 2))
        #expect(await replacement.isMediaReady == false)

        await #expect(throws: NativeDAVEControlAdapterError.transitionProtocolUnavailable) {
            _ = try await adapter.handle(
                executeFrame(transitionID: 40),
                event: .transitionExecuted(40)
            )
        }
        _ = try await adapter.handle(proposalsFrame(), event: .mlsPayloadReceived(.proposals))
        #expect(await active.proposalCallCount == 0)
        #expect(await replacement.proposalCallCount == 1)

        let ready = try await adapter.handle(
            welcomeFrame(transitionID: 40),
            event: .requiresMLSProcessing(40)
        )
        #expect(ready.map(\.opcode) == [.transitionReady])
        _ = try await adapter.handle(
            executeFrame(transitionID: 40),
            event: .transitionExecuted(40)
        )
        _ = try await adapter.handle(proposalsFrame(), event: .mlsPayloadReceived(.proposals))
        #expect(await replacement.proposalCallCount == 2)
    }

    @Test("non-native processing errors propagate without manufacturing recovery")
    func recoveryCatchesOnlyTypedNativeMLSErrors() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(initiallyReady: true, processing: .succeed),
            .init(initiallyReady: false, processing: .failForeign),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 1_000, selfUserID: 1_001)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        _ = try await adapter.handle(
            prepareEpochFrame(transitionID: 50, epoch: 5),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 50,
                epoch: 5
            ))
        )

        await #expect(throws: NativeDAVEControlSessionDouble.ForeignFailure.self) {
            _ = try await adapter.handle(
                commitFrame(transitionID: 50),
                event: .requiresMLSProcessing(50)
            )
        }
        #expect(factory.sessionCount == 2)
        await #expect(throws: NativeDAVEControlAdapterError.transitionProtocolUnavailable) {
            _ = try await adapter.handle(
                executeFrame(transitionID: 50),
                event: .transitionExecuted(50)
            )
        }
    }

    @Test("a suspended proposal is rejected after reset invalidates the active generation")
    func suspendedProposalCannotCompleteAfterReset() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(
                initiallyReady: true,
                processing: .succeed,
                suspensions: [.proposals]
            ),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 1_100, selfUserID: 1_101)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        let active = try #require(factory.session(at: 0))

        let proposalTask = Task {
            try await adapter.handle(
                proposalsFrame(),
                event: .mlsPayloadReceived(.proposals)
            )
        }
        await active.waitUntilStarted(.proposals)
        await adapter.reset()
        await active.release(.proposals)

        await #expect(throws: NativeDAVEControlAdapterError.staleOperation) {
            _ = try await proposalTask.value
        }
        #expect(await adapter.mediaSession() == nil)
    }

    @Test("a suspended proposal cannot publish output after Execute promotes a replacement")
    func suspendedProposalCannotCompleteAfterExecute() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(
                initiallyReady: true,
                processing: .succeed,
                suspensions: [.proposals]
            ),
            .init(initiallyReady: false, processing: .succeed),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 1_200, selfUserID: 1_201)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        let active = try #require(factory.session(at: 0))

        let proposalTask = Task {
            try await adapter.handle(
                proposalsFrame(),
                event: .mlsPayloadReceived(.proposals)
            )
        }
        await active.waitUntilStarted(.proposals)

        _ = try await adapter.handle(
            prepareEpochFrame(transitionID: 60, epoch: 6),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 60,
                epoch: 6
            ))
        )
        _ = try await adapter.handle(
            welcomeFrame(transitionID: 60),
            event: .requiresMLSProcessing(60)
        )
        let replacement = try #require(factory.session(at: 1))
        _ = try await adapter.handle(
            executeFrame(transitionID: 60),
            event: .transitionExecuted(60)
        )
        await active.release(.proposals)

        await #expect(throws: NativeDAVEControlAdapterError.staleOperation) {
            _ = try await proposalTask.value
        }
        _ = try await adapter.handle(
            proposalsFrame(),
            event: .mlsPayloadReceived(.proposals)
        )
        #expect(await replacement.proposalCallCount == 1)
    }

    @Test("a suspended External Sender cannot write through a replacement begin")
    func suspendedExternalSenderCannotCompleteAfterReplacement() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(
                initiallyReady: true,
                processing: .succeed,
                suspensions: [.externalSender]
            ),
            .init(initiallyReady: true, processing: .succeed),
            .init(initiallyReady: false, processing: .succeed),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let firstContext = try VoiceGatewayDAVEConnectionContext(
            groupID: 1_300,
            selfUserID: 1_301
        )
        _ = try await adapter.beginSession(context: firstContext, protocolVersion: 1)
        let first = try #require(factory.session(at: 0))

        let senderTask = Task {
            try await adapter.handle(
                externalSenderFrame(),
                event: .externalSenderRetained
            )
        }
        await first.waitUntilStarted(.externalSender)

        let replacementContext = try VoiceGatewayDAVEConnectionContext(
            groupID: 1_400,
            selfUserID: 1_401
        )
        _ = try await adapter.beginSession(
            context: replacementContext,
            protocolVersion: 1
        )
        let replacement = try #require(factory.session(at: 1))
        await first.release(.externalSender)

        await #expect(throws: NativeDAVEControlAdapterError.staleOperation) {
            _ = try await senderTask.value
        }
        #expect(await replacement.externalSenderCallCount == 0)

        _ = try await adapter.handle(
            prepareEpochFrame(transitionID: 70, epoch: 7),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 70,
                epoch: 7
            ))
        )
        let pending = try #require(factory.session(at: 2))
        #expect(await pending.externalSenderCallCount == 0)
    }

    @Test("duplicated transition fields must match before state or native work")
    func transitionEventAndFrameMustMatch() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(initiallyReady: true, processing: .succeed),
            .init(initiallyReady: false, processing: .succeed),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 1_500, selfUserID: 1_501)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)

        await #expect(throws: NativeDAVEControlAdapterError.transitionEventMismatch) {
            _ = try await adapter.handle(
                downgradeFrame(transitionID: 80),
                event: .transitionPrepared(81)
            )
        }

        let epochFrame = prepareEpochFrame(transitionID: 82, epoch: 8)
        await #expect(throws: NativeDAVEControlAdapterError.transitionEventMismatch) {
            _ = try await adapter.handle(
                epochFrame,
                event: .epochAnnounced(.init(
                    protocolVersion: 1,
                    transitionID: 83,
                    epoch: 8
                ))
            )
        }
        await #expect(throws: NativeDAVEControlAdapterError.transitionEventMismatch) {
            _ = try await adapter.handle(
                epochFrame,
                event: .epochAnnounced(.init(
                    protocolVersion: 2,
                    transitionID: 82,
                    epoch: 8
                ))
            )
        }
        await #expect(throws: NativeDAVEControlAdapterError.transitionEventMismatch) {
            _ = try await adapter.handle(
                epochFrame,
                event: .epochAnnounced(.init(
                    protocolVersion: 1,
                    transitionID: 82,
                    epoch: 9
                ))
            )
        }
        #expect(factory.sessionCount == 1)

        _ = try await adapter.handle(
            epochFrame,
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 82,
                epoch: 8
            ))
        )
        let pending = try #require(factory.session(at: 1))

        await #expect(throws: NativeDAVEControlAdapterError.transitionEventMismatch) {
            _ = try await adapter.handle(
                commitFrame(transitionID: 82),
                event: .requiresMLSProcessing(83)
            )
        }
        await #expect(throws: NativeDAVEControlAdapterError.transitionEventMismatch) {
            _ = try await adapter.handle(
                welcomeFrame(transitionID: 82),
                event: .requiresMLSProcessing(83)
            )
        }
        #expect(await pending.commitCallCount == 0)
        #expect(await pending.welcomeCallCount == 0)

        _ = try await adapter.handle(
            welcomeFrame(transitionID: 82),
            event: .requiresMLSProcessing(82)
        )
        await #expect(throws: NativeDAVEControlAdapterError.transitionEventMismatch) {
            _ = try await adapter.handle(
                executeFrame(transitionID: 82),
                event: .transitionExecuted(83)
            )
        }
        _ = try await adapter.handle(
            executeFrame(transitionID: 82),
            event: .transitionExecuted(82)
        )
        #expect(await pending.welcomeCallCount == 1)
    }

    @Test("Proposals use the in-flight pending Key Package session")
    func proposalsPreferPendingSession() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(initiallyReady: true, processing: .succeed),
            .init(initiallyReady: false, processing: .succeed),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 1_600, selfUserID: 1_601)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        let active = try #require(factory.session(at: 0))

        _ = try await adapter.handle(
            prepareEpochFrame(transitionID: 90, epoch: 9),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 90,
                epoch: 9
            ))
        )
        let pending = try #require(factory.session(at: 1))

        _ = try await adapter.handle(
            proposalsFrame(),
            event: .mlsPayloadReceived(.proposals)
        )
        #expect(await active.proposalCallCount == 0)
        #expect(await pending.proposalCallCount == 1)
    }

    @Test("membership replacement invalidates a suspended pending Proposals result")
    func membershipChangeInvalidatesSuspendedProposals() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(initiallyReady: true, processing: .succeed),
            .init(
                initiallyReady: false,
                processing: .succeed,
                suspensions: [.proposals]
            ),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 1_700, selfUserID: 1_701)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        _ = try await adapter.handle(
            prepareEpochFrame(transitionID: 100, epoch: 10),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 100,
                epoch: 10
            ))
        )
        let pending = try #require(factory.session(at: 1))

        let proposalTask = Task {
            try await adapter.handle(
                proposalsFrame(),
                event: .mlsPayloadReceived(.proposals)
            )
        }
        await pending.waitUntilStarted(.proposals)
        await adapter.replaceRecognizedUserIDs([1_701, 1_702])
        await pending.release(.proposals)

        await #expect(throws: NativeDAVEControlAdapterError.staleOperation) {
            _ = try await proposalTask.value
        }
    }

    @Test("membership replacement invalidates a suspended Welcome before readiness")
    func membershipChangeInvalidatesSuspendedWelcome() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(initiallyReady: true, processing: .succeed),
            .init(
                initiallyReady: false,
                processing: .succeed,
                suspensions: [.welcome]
            ),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 1_800, selfUserID: 1_801)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        _ = try await adapter.handle(
            prepareEpochFrame(transitionID: 110, epoch: 11),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 110,
                epoch: 11
            ))
        )
        let pending = try #require(factory.session(at: 1))

        let welcomeTask = Task {
            try await adapter.handle(
                welcomeFrame(transitionID: 110),
                event: .requiresMLSProcessing(110)
            )
        }
        await pending.waitUntilStarted(.welcome)
        await adapter.replaceRecognizedUserIDs([1_801, 1_802])
        await pending.release(.welcome)

        await #expect(throws: NativeDAVEControlAdapterError.staleOperation) {
            _ = try await welcomeTask.value
        }
        await #expect(throws: NativeDAVEControlAdapterError.transitionProtocolUnavailable) {
            _ = try await adapter.handle(
                executeFrame(transitionID: 110),
                event: .transitionExecuted(110)
            )
        }
    }

    @Test("an ignored duplicate Commit emits no readiness and cannot execute")
    func ignoredCommitDoesNotBecomeReady() async throws {
        let factory = NativeDAVEControlSessionFactoryDouble(specifications: [
            .init(initiallyReady: true, processing: .succeed),
            // The native actor is deliberately already ready: adapter readiness
            // must still remain false when libdave reports an ignored Commit.
            .init(initiallyReady: true, processing: .ignoreCommit),
        ])
        let adapter = NativeDAVEControlAdapter(sessionFactory: factory.makeSession)
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 1_900, selfUserID: 1_901)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        _ = try await adapter.handle(
            prepareEpochFrame(transitionID: 120, epoch: 12),
            event: .epochAnnounced(.init(
                protocolVersion: 1,
                transitionID: 120,
                epoch: 12
            ))
        )

        let outbound = try await adapter.handle(
            commitFrame(transitionID: 120),
            event: .requiresMLSProcessing(120)
        )
        #expect(outbound.isEmpty)
        await #expect(throws: NativeDAVEControlAdapterError.transitionProtocolUnavailable) {
            _ = try await adapter.handle(
                executeFrame(transitionID: 120),
                event: .transitionExecuted(120)
            )
        }
    }
}

private func downgradeFrame(transitionID: UInt16) -> VoiceGatewayDAVEInboundFrame {
    VoiceGatewayDAVEInboundFrame(
        sequence: nil,
        message: .prepareTransition(.init(
            protocolVersion: 0,
            transitionID: transitionID
        ))
    )
}

private func prepareEpochFrame(
    transitionID: UInt16,
    protocolVersion: UInt16 = 1,
    epoch: UInt64
) -> VoiceGatewayDAVEInboundFrame {
    VoiceGatewayDAVEInboundFrame(
        sequence: nil,
        message: .prepareEpoch(.init(
            protocolVersion: protocolVersion,
            transitionID: transitionID,
            epoch: epoch
        ))
    )
}

private func externalSenderFrame() throws -> VoiceGatewayDAVEInboundFrame {
    VoiceGatewayDAVEInboundFrame(
        sequence: nil,
        message: .externalSenderPackage(.init(
            signatureKey: try VoiceGatewayDAVEOpaquePayload(Data([0xAA])),
            credentialIdentity: try VoiceGatewayDAVEOpaquePayload(Data([0xBB]))
        ))
    )
}

private func executeFrame(transitionID: UInt16) -> VoiceGatewayDAVEInboundFrame {
    VoiceGatewayDAVEInboundFrame(
        sequence: nil,
        message: .executeTransition(.init(transitionID: transitionID))
    )
}

private func commitFrame(transitionID: UInt16) throws -> VoiceGatewayDAVEInboundFrame {
    VoiceGatewayDAVEInboundFrame(
        sequence: nil,
        message: .announceCommitTransition(.init(
            transitionID: transitionID,
            commit: try VoiceGatewayDAVEOpaquePayload(Data([0xCC]))
        ))
    )
}

private func welcomeFrame(transitionID: UInt16) throws -> VoiceGatewayDAVEInboundFrame {
    VoiceGatewayDAVEInboundFrame(
        sequence: nil,
        message: .welcome(.init(
            transitionID: transitionID,
            welcome: try VoiceGatewayDAVEOpaquePayload(Data([0xDD]))
        ))
    )
}

private func proposalsFrame() throws -> VoiceGatewayDAVEInboundFrame {
    VoiceGatewayDAVEInboundFrame(
        sequence: nil,
        message: .proposals(.init(
            operation: .append,
            vector: try VoiceGatewayDAVEOpaquePayload(Data([0xEE]))
        ))
    )
}

private final class NativeDAVEControlSessionFactoryDouble: @unchecked Sendable {
    struct Specification: Sendable {
        let initiallyReady: Bool
        let processing: NativeDAVEControlSessionDouble.Processing
        let suspensions: Set<NativeDAVEControlSessionDouble.Suspension>

        init(
            initiallyReady: Bool,
            processing: NativeDAVEControlSessionDouble.Processing,
            suspensions: Set<NativeDAVEControlSessionDouble.Suspension> = []
        ) {
            self.initiallyReady = initiallyReady
            self.processing = processing
            self.suspensions = suspensions
        }
    }

    private let lock = NSLock()
    private var specifications: [Specification]
    private var sessions: [NativeDAVEControlSessionDouble] = []

    init(specifications: [Specification]) {
        self.specifications = specifications
    }

    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    func session(at index: Int) -> NativeDAVEControlSessionDouble? {
        lock.lock()
        defer { lock.unlock() }
        guard sessions.indices.contains(index) else { return nil }
        return sessions[index]
    }

    func makeSession(
        protocolVersion: UInt16,
        groupID: UInt64,
        selfUserID: String
    ) throws -> any NativeDAVEControlSession {
        _ = groupID
        _ = selfUserID
        lock.lock()
        defer { lock.unlock() }
        guard !specifications.isEmpty else {
            throw NativeDAVEControlAdapterError.sessionUnavailable
        }
        _ = protocolVersion
        let specification = specifications.removeFirst()
        let session = NativeDAVEControlSessionDouble(
            initiallyReady: specification.initiallyReady,
            processing: specification.processing,
            suspensions: specification.suspensions,
            keyPackageMarker: UInt8(truncatingIfNeeded: sessions.count + 1)
        )
        sessions.append(session)
        return session
    }
}

private actor NativeDAVEControlSessionDouble: NativeDAVEControlSession {
    enum ForeignFailure: Error { case injected }

    enum Suspension: Hashable, Sendable {
        case externalSender
        case proposals
        case welcome
    }

    enum Processing: Sendable {
        case succeed
        case failNative(NativeMediaError)
        case failForeign
        case ignoreCommit
    }

    private let processing: Processing
    private let suspensions: Set<Suspension>
    private let keyPackageMarker: UInt8
    private(set) var isMediaReady: Bool
    private(set) var proposalCallCount = 0
    private(set) var externalSenderCallCount = 0
    private(set) var commitCallCount = 0
    private(set) var welcomeCallCount = 0
    private var startedSuspensions: Set<Suspension> = []
    private var startWaiters: [Suspension: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [Suspension: [CheckedContinuation<Void, Never>]] = [:]

    init(
        initiallyReady: Bool,
        processing: Processing,
        suspensions: Set<Suspension>,
        keyPackageMarker: UInt8
    ) {
        isMediaReady = initiallyReady
        self.processing = processing
        self.suspensions = suspensions
        self.keyPackageMarker = keyPackageMarker
    }

    func marshalledKeyPackage() -> Data { Data([keyPackageMarker]) }
    func setExternalSender(_: Data) async {
        externalSenderCallCount += 1
        await suspendIfConfigured(.externalSender)
    }

    func processProposals(
        _: Data,
        recognizedUserIDs _: [String]
    ) async -> Data {
        proposalCallCount += 1
        await suspendIfConfigured(.proposals)
        return Data([0xAC])
    }

    func processCommit(_: Data) throws -> NativeDAVECommitOutcome {
        commitCallCount += 1
        if case .ignoreCommit = processing {
            return .ignored
        }
        try finishProcessing()
        return .applied(rosterMemberIDs: [])
    }

    func processWelcome(
        _: Data,
        recognizedUserIDs _: [String]
    ) async throws -> [UInt64] {
        welcomeCallCount += 1
        await suspendIfConfigured(.welcome)
        try finishProcessing()
        return []
    }

    private func finishProcessing() throws {
        switch processing {
        case .succeed:
            isMediaReady = true
        case .failNative(let error):
            throw error
        case .failForeign:
            throw ForeignFailure.injected
        case .ignoreCommit:
            break
        }
    }

    func waitUntilStarted(_ suspension: Suspension) async {
        guard !startedSuspensions.contains(suspension) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[suspension, default: []].append(continuation)
        }
    }

    func release(_ suspension: Suspension) {
        let waiters = releaseWaiters.removeValue(forKey: suspension) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func suspendIfConfigured(_ suspension: Suspension) async {
        guard suspensions.contains(suspension) else { return }
        startedSuspensions.insert(suspension)
        let waiters = startWaiters.removeValue(forKey: suspension) ?? []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters[suspension, default: []].append(continuation)
        }
    }
}
