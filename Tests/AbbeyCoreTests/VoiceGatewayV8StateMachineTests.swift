import Foundation
import Testing
@testable import AbbeyCore

@Suite("Discord Voice Gateway v8 state machine")
struct VoiceGatewayV8StateMachineTests {
    private func identity() throws -> VoiceGatewayV8Identify {
        try VoiceGatewayV8Identify(
            serverID: "guild",
            userID: "bot",
            sessionID: "session",
            token: "ephemeral-token"
        )
    }

    @Test("valid identify-to-media transcript tracks sequence and heartbeat ACK")
    func validTranscript() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        guard case .identify(let identify) = try machine.opened() else {
            Issue.record("Expected Identify")
            return
        }
        #expect(identify.maxDAVEProtocolVersion == 0)

        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 10,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 1_000))
            ),
            nowMilliseconds: 5_000
        )
        #expect(machine.phase == .awaitingReady)
        #expect(try machine.heartbeatIfDue(nowMilliseconds: 5_999) == nil)

        guard case .heartbeat(let heartbeat) = try machine.heartbeatIfDue(nowMilliseconds: 6_000) else {
            Issue.record("Expected due Heartbeat")
            return
        }
        #expect(heartbeat.t == 6_000)
        #expect(heartbeat.sequenceAcknowledgement == 10)
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 11,
                payload: .heartbeatACK(VoiceGatewayV8HeartbeatACK(t: 6_000))
            ),
            nowMilliseconds: 6_020
        )
        #expect(machine.pendingHeartbeatTimestamp == nil)

        let encryptionMode = "aead_xchacha20_poly1305_rtpsize"
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 12,
                payload: .ready(try VoiceGatewayV8Ready(
                    ssrc: 77,
                    ip: "203.0.113.10",
                    port: 50_000,
                    modes: [encryptionMode]
                ))
            ),
            nowMilliseconds: 6_100
        )
        #expect(machine.phase == .ready)
        #expect(machine.lastReceivedSequence == 12)

        guard case .selectProtocol(let selection) = try machine.selectProtocol(
            address: "198.51.100.8",
            port: 60_000,
            mode: encryptionMode
        ) else {
            Issue.record("Expected Select Protocol")
            return
        }
        #expect(selection.protocolName == "udp")
        #expect(selection.data.mode == encryptionMode)

        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 13,
                payload: .sessionDescription(try VoiceGatewayV8SessionDescription(
                    mode: encryptionMode,
                    secretKey: Array(repeating: 7, count: 32),
                    daveProtocolVersion: 0
                ))
            ),
            nowMilliseconds: 6_200
        )
        #expect(machine.phase == .established)
        #expect(machine.resumeEligible)

        guard case .speaking(let speaking) = try machine.speaking(flags: 1) else {
            Issue.record("Expected Speaking")
            return
        }
        #expect(speaking.ssrc == 77)
        #expect(speaking.speaking == 1)
    }

    @Test("a pending heartbeat that misses one interval requires reconnect")
    func missedHeartbeatACK() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        _ = try machine.opened()
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 1,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 1_000))
            ),
            nowMilliseconds: 0
        )
        _ = try machine.heartbeatIfDue(nowMilliseconds: 1_000)

        #expect(throws: VoiceGatewayV8Error.missedHeartbeatAcknowledgement) {
            _ = try machine.heartbeatIfDue(nowMilliseconds: 2_000)
        }
        #expect(machine.phase == .reconnectRequired)
    }

    @Test("sequence tracking is monotonic and feeds the resume payload")
    func sequenceAndResume() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        _ = try machine.opened()
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 20,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 5_000))
            ),
            nowMilliseconds: 0
        )
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 19,
                payload: .ready(try VoiceGatewayV8Ready(
                    ssrc: 5,
                    ip: "203.0.113.2",
                    port: 50_000,
                    modes: ["aead_aes256_gcm_rtpsize"]
                ))
            ),
            nowMilliseconds: 1
        )
        #expect(machine.lastReceivedSequence == 20)

        let resume = try machine.resumePayload()
        #expect(resume.serverID == "guild")
        #expect(resume.sessionID == "session")
        #expect(resume.sequenceAcknowledgement == 20)
        #expect(!String(describing: resume).contains("ephemeral-token"))

        #expect(machine.handleClose(code: 4015) == .resume)
        guard case .resume(let outboundResume) = try machine.opened(resuming: true) else {
            Issue.record("Expected Resume")
            return
        }
        #expect(outboundResume.sequenceAcknowledgement == 20)
        try machine.receive(
            VoiceGatewayV8Inbound(sequence: 21, payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 5_000))),
            nowMilliseconds: 10
        )
        try machine.receive(
            VoiceGatewayV8Inbound(sequence: 22, payload: .resumed(VoiceGatewayV8Resumed())),
            nowMilliseconds: 20
        )
        #expect(machine.phase == .established)
    }

    @Test("close codes choose resume, reidentify, or terminal explicitly")
    func closeDispositions() {
        #expect(VoiceGatewayV8StateMachine.CloseDisposition.classify(code: 4015, resumeEligible: true) == .resume)
        #expect(VoiceGatewayV8StateMachine.CloseDisposition.classify(code: 4015, resumeEligible: false) == .reidentify)
        #expect(VoiceGatewayV8StateMachine.CloseDisposition.classify(code: 4006, resumeEligible: true) == .reidentify)
        #expect(VoiceGatewayV8StateMachine.CloseDisposition.classify(code: 4009, resumeEligible: true) == .reidentify)
        #expect(VoiceGatewayV8StateMachine.CloseDisposition.classify(code: 4004, resumeEligible: true) == .terminal)
        #expect(VoiceGatewayV8StateMachine.CloseDisposition.classify(code: 4014, resumeEligible: true) == .terminal)
        #expect(VoiceGatewayV8StateMachine.CloseDisposition.classify(code: 4999, resumeEligible: true) == .terminal)
    }

    @Test("invalid event order and heartbeat ACK mismatch fail closed")
    func invalidOrdering() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        #expect(throws: VoiceGatewayV8Error.unexpectedEvent) {
            _ = try machine.selectProtocol(address: "127.0.0.1", port: 50_000, mode: "mode")
        }
        _ = try machine.opened()
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 1,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 1_000))
            ),
            nowMilliseconds: 0
        )
        _ = try machine.heartbeatIfDue(nowMilliseconds: 1_000)
        #expect(throws: VoiceGatewayV8Error.heartbeatAcknowledgementMismatch) {
            try machine.receive(
                VoiceGatewayV8Inbound(
                    sequence: 2,
                    payload: .heartbeatACK(VoiceGatewayV8HeartbeatACK(t: 999))
                ),
                nowMilliseconds: 1_001
            )
        }
    }
}
