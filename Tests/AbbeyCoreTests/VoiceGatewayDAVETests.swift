import Foundation
import Testing
@testable import AbbeyCore

@Suite("Discord Voice Gateway DAVE framing")
struct VoiceGatewayDAVETests {
    @Test("opcode metadata matches the official JSON, binary, and direction table")
    func opcodeMetadata() {
        #expect(VoiceGatewayDAVEOpcode.allCases.map(\.rawValue) == Array(21...31))

        #expect(VoiceGatewayDAVEOpcode.prepareTransition.representation == .json)
        #expect(VoiceGatewayDAVEOpcode.executeTransition.representation == .json)
        #expect(VoiceGatewayDAVEOpcode.transitionReady.representation == .json)
        #expect(VoiceGatewayDAVEOpcode.prepareEpoch.representation == .json)
        #expect(VoiceGatewayDAVEOpcode.invalidCommitWelcome.representation == .json)

        for opcode in [
            VoiceGatewayDAVEOpcode.externalSenderPackage,
            .keyPackage,
            .proposals,
            .commitWelcome,
            .announceCommitTransition,
            .welcome,
        ] {
            #expect(opcode.representation == .binary)
        }

        for opcode in [
            VoiceGatewayDAVEOpcode.transitionReady,
            .keyPackage,
            .commitWelcome,
            .invalidCommitWelcome,
        ] {
            #expect(opcode.direction == .clientToServer)
        }
    }

    @Test("server JSON transition and epoch messages decode with bounded integer fields")
    func serverJSONFixtures() throws {
        let prepare = try VoiceGatewayDAVECodec.decodeServerJSON(
            Data(#"{"op":21,"d":{"protocol_version":0,"transition_id":4660},"seq":65535}"#.utf8)
        )
        #expect(prepare.sequence == .max)
        guard case .prepareTransition(let payload) = prepare.message else {
            Issue.record("Expected prepare transition")
            return
        }
        #expect(payload.protocolVersion == 0)
        #expect(payload.transitionID == 0x1234)

        let execute = try VoiceGatewayDAVECodec.decodeServerJSON(
            Data(#"{"op":22,"d":{"transition_id":4660},"seq":0}"#.utf8)
        )
        guard case .executeTransition(let executePayload) = execute.message else {
            Issue.record("Expected execute transition")
            return
        }
        #expect(executePayload.transitionID == 0x1234)

        let epoch = try VoiceGatewayDAVECodec.decodeServerJSON(
            Data(#"{"op":24,"d":{"protocol_version":1,"transition_id":9,"epoch":18446744073709551615},"seq":7}"#.utf8)
        )
        guard case .prepareEpoch(let epochPayload) = epoch.message else {
            Issue.record("Expected prepare epoch")
            return
        }
        #expect(epochPayload.protocolVersion == 1)
        #expect(epochPayload.transitionID == 9)
        #expect(epochPayload.epoch == .max)
    }

    @Test("client JSON messages round trip without a server sequence")
    func clientJSONRoundTrip() throws {
        let ready = VoiceGatewayDAVEClientMessage.transitionReady(
            VoiceGatewayDAVETransitionReady(transitionID: 513)
        )
        let readyFrame = try VoiceGatewayDAVECodec.encodeClient(ready)
        #expect(readyFrame.representation == .json)
        #expect(try VoiceGatewayDAVECodec.decodeClientJSON(readyFrame.bytes) == ready)

        let object = try #require(JSONSerialization.jsonObject(with: readyFrame.bytes) as? [String: Any])
        #expect(object["op"] as? Int == 23)
        #expect(object["seq"] == nil)
        let body = try #require(object["d"] as? [String: Any])
        #expect(body["transition_id"] as? Int == 513)

        let invalid = VoiceGatewayDAVEClientMessage.invalidCommitWelcome(
            VoiceGatewayDAVEInvalidCommitWelcome(transitionID: 514)
        )
        let invalidFrame = try VoiceGatewayDAVECodec.encodeClient(invalid)
        #expect(try VoiceGatewayDAVECodec.decodeClientJSON(invalidFrame.bytes) == invalid)
    }

    @Test("external sender package decodes MLS vectors and the basic credential type")
    func externalSenderFixture() throws {
        let frame = Data([
            0x12, 0x34,
            VoiceGatewayDAVEOpcode.externalSenderPackage.rawValue,
            0x03, 0xAA, 0xBB, 0xCC,
            0x00, 0x01,
            0x02, 0xDD, 0xEE,
        ])
        let decoded = try VoiceGatewayDAVECodec.decodeServerBinary(frame)
        #expect(decoded.sequence == 0x1234)
        guard case .externalSenderPackage(let package) = decoded.message else {
            Issue.record("Expected external sender package")
            return
        }
        #expect(package.signatureKey.bytes == Data([0xAA, 0xBB, 0xCC]))
        #expect(package.credentialIdentity.bytes == Data([0xDD, 0xEE]))
    }

    @Test("MLS two-byte vector length is decoded canonically")
    func twoByteVectorLength() throws {
        var frame = Data([
            0x00, 0x01,
            VoiceGatewayDAVEOpcode.externalSenderPackage.rawValue,
            0x40, 0x40,
        ])
        frame.append(Data(repeating: 0xAB, count: 64))
        frame.append(contentsOf: [0x00, 0x01, 0x01, 0xCD])

        let decoded = try VoiceGatewayDAVECodec.decodeServerBinary(frame)
        guard case .externalSenderPackage(let package) = decoded.message else {
            Issue.record("Expected external sender package")
            return
        }
        #expect(package.signatureKey.count == 64)
        #expect(package.credentialIdentity.bytes == Data([0xCD]))
    }

    @Test("proposal append and revoke fixtures preserve their bounded opaque vectors")
    func proposalsFixtures() throws {
        let append = try VoiceGatewayDAVECodec.decodeServerBinary(Data([
            0x00, 0x02,
            VoiceGatewayDAVEOpcode.proposals.rawValue,
            VoiceGatewayDAVEProposalsOperation.append.rawValue,
            0x03, 0x10, 0x20, 0x30,
        ]))
        guard case .proposals(let appendPayload) = append.message else {
            Issue.record("Expected append proposals")
            return
        }
        #expect(appendPayload.operation == .append)
        #expect(appendPayload.vector.bytes == Data([0x10, 0x20, 0x30]))

        let revoke = try VoiceGatewayDAVECodec.decodeServerBinary(Data([
            0x00, 0x03,
            VoiceGatewayDAVEOpcode.proposals.rawValue,
            VoiceGatewayDAVEProposalsOperation.revoke.rawValue,
            0x02, 0x40, 0x50,
        ]))
        guard case .proposals(let revokePayload) = revoke.message else {
            Issue.record("Expected revoke proposals")
            return
        }
        #expect(revokePayload.operation == .revoke)
        #expect(revokePayload.vector.bytes == Data([0x40, 0x50]))
    }

    @Test("commit transition and welcome use big-endian transition IDs after the sequence and opcode")
    func transitionIDFraming() throws {
        let commit = try VoiceGatewayDAVECodec.decodeServerBinary(Data([
            0xAB, 0xCD,
            VoiceGatewayDAVEOpcode.announceCommitTransition.rawValue,
            0x12, 0x34,
            0xDE, 0xAD,
        ]))
        #expect(commit.sequence == 0xABCD)
        guard case .announceCommitTransition(let commitPayload) = commit.message else {
            Issue.record("Expected announced commit")
            return
        }
        #expect(commitPayload.transitionID == 0x1234)
        #expect(commitPayload.commit.bytes == Data([0xDE, 0xAD]))

        let welcome = try VoiceGatewayDAVECodec.decodeServerBinary(Data([
            0xAB, 0xCE,
            VoiceGatewayDAVEOpcode.welcome.rawValue,
            0xFE, 0xDC,
            0xBE, 0xEF,
        ]))
        guard case .welcome(let welcomePayload) = welcome.message else {
            Issue.record("Expected welcome")
            return
        }
        #expect(welcomePayload.transitionID == 0xFEDC)
        #expect(welcomePayload.welcome.bytes == Data([0xBE, 0xEF]))
    }

    @Test("client binary key package and commit welcome have no sequence prefix and round trip")
    func clientBinaryRoundTrip() throws {
        let keyBytes = try VoiceGatewayDAVEOpaquePayload(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        let keyMessage = VoiceGatewayDAVEClientMessage.keyPackage(keyBytes)
        let keyFrame = try VoiceGatewayDAVECodec.encodeClient(keyMessage)
        #expect(keyFrame.representation == .binary)
        #expect(keyFrame.bytes == Data([26, 0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(try VoiceGatewayDAVECodec.decodeClientBinary(keyFrame.bytes) == keyMessage)

        let commitBytes = try VoiceGatewayDAVEOpaquePayload(Data([0x01, 0x02, 0x03]))
        let commitMessage = VoiceGatewayDAVEClientMessage.commitWelcome(commitBytes)
        let commitFrame = try VoiceGatewayDAVECodec.encodeClient(commitMessage)
        #expect(commitFrame.bytes == Data([28, 0x01, 0x02, 0x03]))
        #expect(try VoiceGatewayDAVECodec.decodeClientBinary(commitFrame.bytes) == commitMessage)
    }

    @Test("wrong representations, directions, unknown opcodes, and invalid JSON bounds are rejected")
    func representationAndJSONRejections() {
        #expect(throws: VoiceGatewayDAVEError.wrongDirection(opcode: 23)) {
            _ = try VoiceGatewayDAVECodec.decodeServerJSON(
                Data(#"{"op":23,"d":{"transition_id":1}}"#.utf8)
            )
        }
        #expect(throws: VoiceGatewayDAVEError.wrongRepresentation(opcode: 25)) {
            _ = try VoiceGatewayDAVECodec.decodeServerJSON(Data(#"{"op":25,"d":{}}"#.utf8))
        }
        #expect(throws: VoiceGatewayDAVEError.wrongDirection(opcode: 26)) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(Data([0, 1, 26, 1]))
        }
        #expect(throws: VoiceGatewayDAVEError.unknownOpcode(255)) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(Data([0, 1, 255, 1]))
        }
        #expect(throws: VoiceGatewayDAVEError.malformedJSON) {
            _ = try VoiceGatewayDAVECodec.decodeServerJSON(
                Data(#"{"op":21,"d":{"protocol_version":1,"transition_id":65536}}"#.utf8)
            )
        }
        #expect(throws: VoiceGatewayDAVEError.unexpectedSequence) {
            _ = try VoiceGatewayDAVECodec.decodeClientJSON(
                Data(#"{"op":23,"d":{"transition_id":1},"seq":2}"#.utf8)
            )
        }
    }

    @Test("truncation, invalid vector lengths, trailing bytes, and malformed operations are rejected")
    func malformedBinaryRejections() {
        #expect(throws: VoiceGatewayDAVEError.truncatedBinary) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(Data([0, 1]))
        }
        #expect(throws: VoiceGatewayDAVEError.truncatedBinary) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(Data([0, 1, 29, 0]))
        }
        #expect(throws: VoiceGatewayDAVEError.emptyPayload) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(Data([0, 1, 29, 0, 2]))
        }
        #expect(throws: VoiceGatewayDAVEError.nonCanonicalVectorLength) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(Data([0, 1, 25, 0x40, 0x01, 0xAA]))
        }
        #expect(throws: VoiceGatewayDAVEError.unsupportedVectorLength) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(Data([0, 1, 25, 0xC0]))
        }
        #expect(throws: VoiceGatewayDAVEError.invalidCredentialType(2)) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(
                Data([0, 1, 25, 1, 0xAA, 0, 2, 1, 0xBB])
            )
        }
        #expect(throws: VoiceGatewayDAVEError.invalidProposalsOperation(2)) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(Data([0, 1, 27, 2, 1, 0xAA]))
        }
        #expect(throws: VoiceGatewayDAVEError.malformedBinary) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(
                Data([0, 1, 27, 0, 1, 0xAA, 0xBB])
            )
        }
        #expect(throws: VoiceGatewayDAVEError.emptyPayload) {
            _ = try VoiceGatewayDAVECodec.decodeClientBinary(Data([26]))
        }
    }

    @Test("all opaque payloads remain redacted from descriptions, debug output, and mirrors")
    func redaction() throws {
        let secretPattern = Data([222, 173, 190, 239])
        let opaque = try VoiceGatewayDAVEOpaquePayload(secretPattern)
        let message = VoiceGatewayDAVEClientMessage.keyPackage(opaque)
        let frame = try VoiceGatewayDAVECodec.encodeClient(message)
        let inbound = try VoiceGatewayDAVECodec.decodeServerBinary(
            Data([0, 7, 29, 0, 8, 222, 173, 190, 239])
        )

        var rendered = ""
        dump(opaque, to: &rendered)
        dump(message, to: &rendered)
        dump(frame, to: &rendered)
        dump(inbound, to: &rendered)
        rendered += String(describing: opaque)
        rendered += String(reflecting: message)
        rendered += String(reflecting: inbound)

        #expect(rendered.contains("<redacted"))
        #expect(!rendered.contains("222"))
        #expect(!rendered.contains("173"))
        #expect(!rendered.lowercased().contains("deadbeef"))
    }

    @Test("transition state refuses execution before preparation")
    func transitionStateOrdering() throws {
        var state = VoiceGatewayDAVETransitionStateMachine()
        #expect(VoiceGatewayDAVETransitionStateMachine.advertisedProtocolVersion == 0)

        #expect(throws: VoiceGatewayDAVEError.transitionNotPrepared(10)) {
            _ = try state.receive(
                .executeTransition(VoiceGatewayDAVEExecuteTransition(transitionID: 10))
            )
        }

        #expect(
            try state.receive(
                .prepareTransition(
                    VoiceGatewayDAVEPrepareTransition(protocolVersion: 0, transitionID: 10)
                )
            ) == .transitionPrepared(10)
        )
        #expect(
            try state.transitionReadyMessage(transitionID: 10) ==
                .transitionReady(VoiceGatewayDAVETransitionReady(transitionID: 10))
        )
        #expect(
            try state.receive(
                .executeTransition(VoiceGatewayDAVEExecuteTransition(transitionID: 10))
            ) == .transitionExecuted(10)
        )
        #expect(state.preparedTransitionID == nil)
        #expect(state.executedTransitionID == 10)
    }

    @Test("MLS commit or welcome requires successful native processing before readiness")
    func mlsTransitionState() throws {
        var state = VoiceGatewayDAVETransitionStateMachine()
        let commit = try VoiceGatewayDAVEOpaquePayload(Data([1, 2, 3]))
        #expect(
            try state.receive(
                .announceCommitTransition(
                    VoiceGatewayDAVEAnnounceCommitTransition(transitionID: 42, commit: commit)
                )
            ) == .requiresMLSProcessing(42)
        )
        #expect(state.awaitingMLSProcessingTransitionID == 42)
        #expect(throws: VoiceGatewayDAVEError.transitionNotPrepared(42)) {
            _ = try state.transitionReadyMessage(transitionID: 42)
        }
        #expect(try state.markMLSProcessed(transitionID: 42) == .transitionReady(42))
        #expect(try state.transitionReadyMessage(transitionID: 42).opcode == .transitionReady)
        #expect(
            try state.receive(
                .executeTransition(VoiceGatewayDAVEExecuteTransition(transitionID: 42))
            ) == .transitionExecuted(42)
        )
    }

    @Test("Prepare Epoch stages an upgrade and Execute Transition applies versions atomically")
    func upgradeAndDowngradeTransitions() throws {
        var state = VoiceGatewayDAVETransitionStateMachine(maximumProtocolVersion: 1)
        let welcome = try VoiceGatewayDAVEOpaquePayload(Data([0xCA, 0xFE]))
        #expect(
            try state.receive(
                .prepareEpoch(
                    VoiceGatewayDAVEPrepareEpoch(
                        protocolVersion: 1,
                        transitionID: 7,
                        epoch: 1
                    )
                )
            ) == .epochAnnounced(
                .init(protocolVersion: 1, transitionID: 7, epoch: 1)
            )
        )
        #expect(state.effectiveProtocolVersion == 0)
        #expect(state.pendingTargetProtocolVersion == 1)
        #expect(state.preparedTransitionID == nil)
        #expect(
            try state.receive(
                .welcome(
                    VoiceGatewayDAVEWelcome(transitionID: 7, welcome: welcome)
                )
            ) == .requiresMLSProcessing(7)
        )
        #expect(try state.markMLSProcessed(transitionID: 7) == .transitionReady(7))
        #expect(
            try state.receive(
                .executeTransition(VoiceGatewayDAVEExecuteTransition(transitionID: 7))
            ) == .transitionExecuted(7)
        )
        #expect(state.effectiveProtocolVersion == 1)

        #expect(
            try state.receive(
                .prepareTransition(
                    VoiceGatewayDAVEPrepareTransition(protocolVersion: 0, transitionID: 8)
                )
            ) == .transitionPrepared(8)
        )
        #expect(state.effectiveProtocolVersion == 1)
        #expect(
            try state.receive(
                .executeTransition(VoiceGatewayDAVEExecuteTransition(transitionID: 8))
            ) == .transitionExecuted(8)
        )
        #expect(state.effectiveProtocolVersion == 0)
    }

    @Test("External Sender is retained and invalid MLS input resets only the group")
    func externalSenderAndRecovery() throws {
        var state = VoiceGatewayDAVETransitionStateMachine(
            maximumProtocolVersion: 1,
            effectiveProtocolVersion: 1
        )
        let external = VoiceGatewayDAVEExternalSenderPackage(
            signatureKey: try .init(Data([0xAA])),
            credentialIdentity: try .init(Data([0xBB]))
        )
        #expect(
            try state.receive(.externalSenderPackage(external)) == .externalSenderRetained
        )
        #expect(state.externalSenderPackage == external)

        let commit = try VoiceGatewayDAVEOpaquePayload(Data([0xCC]))
        #expect(
            try state.receive(
                .announceCommitTransition(
                    .init(transitionID: 12, commit: commit)
                )
            ) == .requiresMLSProcessing(12)
        )
        #expect(
            try state.resetMLSGroupForRecovery(transitionID: 12) == .recoveryRequired(12)
        )
        #expect(state.effectiveProtocolVersion == 1)
        #expect(state.externalSenderPackage == external)
        #expect(state.awaitingMLSProcessingTransitionID == nil)
    }

    @Test("transition state rejects mismatched overlapping transitions")
    func overlappingTransitionRejection() throws {
        var state = VoiceGatewayDAVETransitionStateMachine()
        _ = try state.receive(
            .prepareTransition(VoiceGatewayDAVEPrepareTransition(protocolVersion: 0, transitionID: 5))
        )
        #expect(throws: VoiceGatewayDAVEError.transitionAlreadyPending(5)) {
            _ = try state.receive(
                .prepareTransition(VoiceGatewayDAVEPrepareTransition(protocolVersion: 0, transitionID: 6))
            )
        }
        #expect(throws: VoiceGatewayDAVEError.transitionMismatch(expected: 5, received: 6)) {
            _ = try state.receive(
                .executeTransition(VoiceGatewayDAVEExecuteTransition(transitionID: 6))
            )
        }
    }

    @Test("bounded deterministic malformed inputs never escape typed codec errors")
    func deterministicFuzzBound() {
        var state: UInt64 = 0xD4A3_2026
        for length in 0..<256 {
            var bytes = [UInt8]()
            bytes.reserveCapacity(length)
            for _ in 0..<length {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bytes.append(UInt8(truncatingIfNeeded: state >> 24))
            }
            do {
                _ = try VoiceGatewayDAVECodec.decodeServerBinary(Data(bytes))
            } catch is VoiceGatewayDAVEError {
                // Expected: fuzz fixtures are structurally invalid in most cases.
            } catch {
                Issue.record("Unexpected error type: \(type(of: error))")
            }
        }

        let oversized = Data(
            repeating: 0,
            count: VoiceGatewayDAVECodec.maximumFrameBytes + 1
        )
        #expect(throws: VoiceGatewayDAVEError.payloadTooLarge) {
            _ = try VoiceGatewayDAVECodec.decodeServerBinary(oversized)
        }
    }

    @Test("portable DAVE control handler is unavailable and fail-closed")
    func portableControlHandlerFailsClosed() async throws {
        let frame = try VoiceGatewayDAVECodec.decodeServerJSON(
            Data(#"{"op":21,"d":{"protocol_version":0,"transition_id":1},"seq":1}"#.utf8)
        )
        var state = VoiceGatewayDAVETransitionStateMachine()
        let event = try state.receive(frame.message)
        let handler = VoiceGatewayDAVEControlHandler.unavailable

        #expect(!handler.isAvailable)
        await #expect(throws: VoiceGatewayDAVEError.controlHandlerUnavailable) {
            _ = try await handler.handle(frame, event: event)
        }

        let secret = "never-render-native-dave-state"
        let capturingHandler = VoiceGatewayDAVEControlHandler { _, _ in
            _ = secret
            return []
        }
        var rendered = ""
        dump(capturingHandler, to: &rendered)
        rendered += String(describing: capturingHandler)
        rendered += String(reflecting: capturingHandler)
        #expect(rendered.contains("<redacted>"))
        #expect(!rendered.contains(secret))
    }
}
