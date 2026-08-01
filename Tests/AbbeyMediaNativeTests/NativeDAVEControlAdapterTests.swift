import AbbeyCore
import Foundation
import Testing
@testable import AbbeyMediaNative

@Suite("Native DAVE control adapter")
struct NativeDAVEControlAdapterTests {
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

    @Test("Prepare Epoch and invalid Commit recovery each replace the full native session")
    func epochAndRecoveryReplaceSession() async throws {
        let adapter = NativeDAVEControlAdapter()
        let context = try VoiceGatewayDAVEConnectionContext(groupID: 500, selfUserID: 600)
        _ = try await adapter.beginSession(context: context, protocolVersion: 1)
        let initialSession = try #require(await adapter.mediaSession())

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
        let epochSession = try #require(await adapter.mediaSession())
        #expect(initialSession !== epochSession)

        let invalidCommit = VoiceGatewayDAVEAnnounceCommitTransition(
            transitionID: 10,
            commit: try VoiceGatewayDAVEOpaquePayload(Data([0xff]))
        )
        let recovery = try await adapter.handle(
            VoiceGatewayDAVEInboundFrame(
                sequence: 1,
                message: .announceCommitTransition(invalidCommit)
            ),
            event: .requiresMLSProcessing(10)
        )
        #expect(recovery.map(\.opcode) == [.invalidCommitWelcome, .keyPackage])
        let recoveredSession = try #require(await adapter.mediaSession())
        #expect(epochSession !== recoveredSession)
        #expect(await recoveredSession.isMediaReady == false)
    }
}
