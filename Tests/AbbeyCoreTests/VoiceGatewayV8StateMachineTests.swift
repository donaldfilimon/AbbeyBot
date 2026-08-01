import Foundation
import Testing
@testable import AbbeyCore

@Suite("Discord Voice Gateway v8 state machine")
struct VoiceGatewayV8StateMachineTests {
    private func identity(maxDAVEProtocolVersion: Int = 0) throws -> VoiceGatewayV8Identify {
        try VoiceGatewayV8Identify(
            serverID: "guild",
            userID: "bot",
            sessionID: "session",
            token: "ephemeral-token",
            maxDAVEProtocolVersion: maxDAVEProtocolVersion
        )
    }

    @Test("valid identify-to-media transcript tracks sequence and heartbeat ACK")
    func validTranscript() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        try machine.opened()
        #expect(machine.phase == .awaitingHello)

        guard case .identify(let identify) = try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 10,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 1_000))
            ),
            nowMilliseconds: 5_000
        ) else {
            Issue.record("Expected Identify")
            return
        }
        #expect(identify.maxDAVEProtocolVersion == 0)
        #expect(machine.phase == .awaitingReady)
        #expect(try machine.heartbeatIfDue(nowMilliseconds: 5_999) == nil)

        try machine.commitServerSequence(Int(UInt16.max))

        guard case .heartbeat(let heartbeat) = try machine.heartbeatIfDue(nowMilliseconds: 6_000) else {
            Issue.record("Expected due Heartbeat")
            return
        }
        #expect(heartbeat.t == 6_000)
        #expect(heartbeat.sequenceAcknowledgement == Int(UInt16.max))
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
        #expect(machine.phase == .awaitingProtocolSelection)
        #expect(machine.lastReceivedSequence == 12)
        #expect(!machine.resumeEligible)

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
        #expect(!machine.resumeEligible)

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

    @Test("accepts a server DAVE version at the client's advertised maximum")
    func negotiatedDAVEVersion() throws {
        let mode = "aead_xchacha20_poly1305_rtpsize"
        var machine = VoiceGatewayV8StateMachine(identity: try identity(maxDAVEProtocolVersion: 2))
        try machine.opened()

        guard case .identify(let identify) = try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 1,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 1_000))
            ),
            nowMilliseconds: 0
        ) else {
            Issue.record("Expected Identify")
            return
        }
        #expect(identify.maxDAVEProtocolVersion == 2)

        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 2,
                payload: .ready(try VoiceGatewayV8Ready(
                    ssrc: 77,
                    ip: "203.0.113.10",
                    port: 50_000,
                    modes: [mode]
                ))
            ),
            nowMilliseconds: 1
        )
        _ = try machine.selectProtocol(address: "198.51.100.8", port: 60_000, mode: mode)
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 3,
                payload: .sessionDescription(try VoiceGatewayV8SessionDescription(
                    mode: mode,
                    secretKey: Array(repeating: 7, count: 32),
                    daveProtocolVersion: 2
                ))
            ),
            nowMilliseconds: 2
        )

        #expect(machine.phase == .established)
        #expect(machine.resumeEligible)
    }

    @Test("rejects a server DAVE version above the client's advertised maximum")
    func rejectsUnadvertisedDAVEVersion() throws {
        let mode = "aead_xchacha20_poly1305_rtpsize"
        var machine = VoiceGatewayV8StateMachine(identity: try identity(maxDAVEProtocolVersion: 1))
        try machine.opened()
        _ = try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 1,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 1_000))
            ),
            nowMilliseconds: 0
        )
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 2,
                payload: .ready(try VoiceGatewayV8Ready(
                    ssrc: 77,
                    ip: "203.0.113.10",
                    port: 50_000,
                    modes: [mode]
                ))
            ),
            nowMilliseconds: 1
        )
        _ = try machine.selectProtocol(address: "198.51.100.8", port: 60_000, mode: mode)

        #expect(throws: VoiceGatewayV8Error.unsupportedDAVEVersion(2)) {
            try machine.receive(
                VoiceGatewayV8Inbound(
                    sequence: 3,
                    payload: .sessionDescription(try VoiceGatewayV8SessionDescription(
                        mode: mode,
                        secretKey: Array(repeating: 7, count: 32),
                        daveProtocolVersion: 2
                    ))
                ),
                nowMilliseconds: 2
            )
        }
        #expect(machine.phase == .awaitingSessionDescription)
        #expect(!machine.resumeEligible)
    }

    @Test("a pending heartbeat that misses one interval requires reconnect")
    func missedHeartbeatACK() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        try machine.opened()
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

    @Test("sequence tracking retains the last validated value across fixed-width wrap")
    func sequenceAndResume() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        try machine.opened()
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: Int.max,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 5_000))
            ),
            nowMilliseconds: 0
        )
        let mode = "aead_aes256_gcm_rtpsize"
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 0,
                payload: .ready(try VoiceGatewayV8Ready(
                    ssrc: 5,
                    ip: "203.0.113.2",
                    port: 50_000,
                    modes: [mode]
                ))
            ),
            nowMilliseconds: 1
        )
        #expect(machine.lastReceivedSequence == 0)
        #expect(!machine.resumeEligible)
        _ = try machine.selectProtocol(address: "198.51.100.2", port: 50_001, mode: mode)
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 1,
                payload: .sessionDescription(try VoiceGatewayV8SessionDescription(
                    mode: mode,
                    secretKey: Array(repeating: 9, count: 32),
                    daveProtocolVersion: 0
                ))
            ),
            nowMilliseconds: 2
        )

        // A separately decoded binary DAVE frame shares the Voice Gateway
        // sequence space and must be reflected in Resume as well.
        try machine.commitServerSequence(Int(UInt16.max))

        let resume = try machine.resumePayload()
        #expect(resume.serverID == "guild")
        #expect(resume.sessionID == "session")
        #expect(resume.sequenceAcknowledgement == Int(UInt16.max))
        #expect(!String(describing: resume).contains("ephemeral-token"))

        #expect(machine.handleClose(code: 4015) == .resume)
        try machine.opened(resuming: true)
        #expect(machine.phase == .awaitingHello)
        guard case .resume(let outboundResume) = try machine.receive(
            VoiceGatewayV8Inbound(sequence: 21, payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 5_000))),
            nowMilliseconds: 10
        ) else {
            Issue.record("Expected Resume")
            return
        }
        #expect(outboundResume.sequenceAcknowledgement == Int(UInt16.max))
        try machine.receive(
            VoiceGatewayV8Inbound(sequence: 22, payload: .resumed(VoiceGatewayV8Resumed())),
            nowMilliseconds: 20
        )
        #expect(machine.phase == .established)
    }

    @Test("normal member lifecycle opcodes do not force reconnect")
    func memberLifecycleEventsRemainInCurrentPhase() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        try machine.opened()
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 1,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 5_000))
            ),
            nowMilliseconds: 0
        )
        let mode = "aead_xchacha20_poly1305_rtpsize"
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 2,
                payload: .ready(try VoiceGatewayV8Ready(
                    ssrc: 5,
                    ip: "203.0.113.2",
                    port: 50_000,
                    modes: [mode]
                ))
            ),
            nowMilliseconds: 1
        )
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 3,
                payload: .clientsConnect(try VoiceGatewayV8ClientsConnect(userIDs: ["member-a", "member-b"]))
            ),
            nowMilliseconds: 2
        )
        #expect(machine.phase == .awaitingProtocolSelection)

        _ = try machine.selectProtocol(address: "198.51.100.2", port: 50_001, mode: mode)
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 4,
                payload: .speaking(try VoiceGatewayV8Speaking(
                    speaking: 1,
                    ssrc: 17,
                    userID: "member-a"
                ))
            ),
            nowMilliseconds: 3
        )
        #expect(machine.phase == .awaitingSessionDescription)

        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 5,
                payload: .sessionDescription(try VoiceGatewayV8SessionDescription(
                    mode: mode,
                    secretKey: Array(repeating: 7, count: 32),
                    daveProtocolVersion: 0
                ))
            ),
            nowMilliseconds: 4
        )
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 6,
                payload: .clientDisconnect(try VoiceGatewayV8ClientDisconnect(userID: "member-b"))
            ),
            nowMilliseconds: 5
        )
        #expect(machine.phase == .established)
        #expect(machine.lastReceivedSequence == 6)
    }

    @Test("Resumed cannot establish a session without a prior media establishment")
    func resumedCannotCreateFalseEstablishedState() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        try machine.opened()
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 1,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 5_000))
            ),
            nowMilliseconds: 0
        )

        #expect(throws: VoiceGatewayV8Error.unexpectedEvent) {
            try machine.receive(
                VoiceGatewayV8Inbound(sequence: 2, payload: .resumed(VoiceGatewayV8Resumed())),
                nowMilliseconds: 1
            )
        }
        #expect(machine.phase == .awaitingReady)
        #expect(!machine.resumeEligible)
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
        try machine.opened()
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

    @Test("an invalid high-sequence event cannot poison resume")
    func invalidSequenceDoesNotAdvanceResumeBoundary() throws {
        var machine = VoiceGatewayV8StateMachine(identity: try identity())
        try machine.opened()
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 10,
                payload: .hello(try VoiceGatewayV8Hello(heartbeatInterval: 1_000))
            ),
            nowMilliseconds: 0
        )
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 12,
                payload: .ready(try VoiceGatewayV8Ready(
                    ssrc: 5,
                    ip: "203.0.113.2",
                    port: 50_000,
                    modes: ["mode"]
                ))
            ),
            nowMilliseconds: 1
        )
        _ = try machine.selectProtocol(address: "198.51.100.2", port: 50_001, mode: "mode")
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 13,
                payload: .sessionDescription(try VoiceGatewayV8SessionDescription(
                    mode: "mode",
                    secretKey: Array(repeating: 3, count: 32),
                    daveProtocolVersion: 0
                ))
            ),
            nowMilliseconds: 2
        )

        #expect(throws: VoiceGatewayV8Error.unexpectedEvent) {
            try machine.receive(
                VoiceGatewayV8Inbound(sequence: 999, payload: .resumed(VoiceGatewayV8Resumed())),
                nowMilliseconds: 3
            )
        }
        #expect(machine.lastReceivedSequence == 13)
        #expect(try machine.resumePayload().sequenceAcknowledgement == 13)
    }
}
