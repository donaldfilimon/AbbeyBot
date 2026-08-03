import Foundation
import Testing
@testable import AbbeyCore

@Suite("Discord Voice Gateway v8 models")
struct VoiceGatewayV8ModelsTests {
    @Test("normalizes a bare ephemeral endpoint to secure Gateway v8")
    func endpointNormalization() throws {
        #expect(try VoiceGatewayV8Endpoint("voice.example.test:443").url.absoluteString == "wss://voice.example.test:443/?v=8")
        #expect(try VoiceGatewayV8Endpoint("wss://voice.example.test/?v=8").url.absoluteString == "wss://voice.example.test/?v=8")
    }

    @Test("rejects unsafe or ambiguous endpoints", arguments: [
        "ws://voice.example.test",
        "https://voice.example.test",
        "wss://user:password@voice.example.test",
        "wss://voice.example.test/#fragment",
        "wss://voice.example.test/not-the-gateway",
        "wss://voice.example.test/?v=7",
        "wss://bad_host.example.test",
        "wss://voice.example.test:",
    ])
    func endpointRejections(value: String) {
        #expect(throws: VoiceGatewayV8Error.self) {
            _ = try VoiceGatewayV8Endpoint(value)
        }
    }

    @Test("outbound envelopes use documented opcode and field names")
    func outboundJSONShape() throws {
        let identify = try VoiceGatewayV8Identify(
            serverID: "guild",
            userID: "bot",
            sessionID: "session",
            token: "ephemeral-token"
        )
        let data = try JSONEncoder().encode(VoiceGatewayV8Outbound.identify(identify))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["d"] as? [String: Any])

        #expect(object["op"] as? Int == 0)
        #expect(payload["server_id"] as? String == "guild")
        #expect(payload["user_id"] as? String == "bot")
        #expect(payload["session_id"] as? String == "session")
        #expect(payload["token"] as? String == "ephemeral-token")
        #expect(payload["max_dave_protocol_version"] as? Int == 0)

        let heartbeat = try VoiceGatewayV8Heartbeat(t: 5_000, sequenceAcknowledgement: 42)
        let heartbeatData = try JSONEncoder().encode(VoiceGatewayV8Outbound.heartbeat(heartbeat))
        let heartbeatObject = try #require(JSONSerialization.jsonObject(with: heartbeatData) as? [String: Any])
        let heartbeatPayload = try #require(heartbeatObject["d"] as? [String: Any])
        #expect(heartbeatObject["op"] as? Int == 3)
        #expect(heartbeatPayload["t"] as? Int == 5_000)
        #expect(heartbeatPayload["seq_ack"] as? Int == 42)
    }

    @Test("decoder validates all modeled inbound events")
    func inboundDecoding() throws {
        let hello = try VoiceGatewayV8Decoder.decode(Data(#"{"op":8,"d":{"heartbeat_interval":5000},"seq":1}"#.utf8))
        guard case .hello(let helloPayload) = hello.payload else {
            Issue.record("Expected Hello")
            return
        }
        #expect(hello.sequence == 1)
        #expect(helloPayload.heartbeatInterval == 5_000)

        let ready = try VoiceGatewayV8Decoder.decode(Data(#"{"op":2,"d":{"ssrc":7,"ip":"203.0.113.4","port":50000,"modes":["aead_xchacha20_poly1305_rtpsize"]},"seq":2}"#.utf8))
        guard case .ready(let readyPayload) = ready.payload else {
            Issue.record("Expected Ready")
            return
        }
        #expect(readyPayload.ssrc == 7)
        #expect(readyPayload.port == 50_000)

        let speaking = try VoiceGatewayV8Decoder.decode(Data(#"{"op":5,"d":{"speaking":1,"delay":0,"ssrc":9,"user_id":"member-a"},"seq":3}"#.utf8))
        guard case .speaking(let speakingPayload) = speaking.payload else {
            Issue.record("Expected Speaking")
            return
        }
        #expect(speakingPayload.userID == "member-a")
        #expect(speakingPayload.ssrc == 9)

        let connected = try VoiceGatewayV8Decoder.decode(Data(#"{"op":11,"d":{"user_ids":["member-a","member-b"]},"seq":4}"#.utf8))
        guard case .clientsConnect(let connectedPayload) = connected.payload else {
            Issue.record("Expected Clients Connect")
            return
        }
        #expect(connectedPayload.userIDs == ["member-a", "member-b"])

        let disconnected = try VoiceGatewayV8Decoder.decode(Data(#"{"op":13,"d":{"user_id":"member-b"},"seq":5}"#.utf8))
        guard case .clientDisconnect(let disconnectedPayload) = disconnected.payload else {
            Issue.record("Expected Client Disconnect")
            return
        }
        #expect(disconnectedPayload.userID == "member-b")
    }

    @Test("decoder rejects malformed and oversized payloads")
    func boundedDecoding() {
        #expect(throws: VoiceGatewayV8Error.invalidHeartbeatInterval) {
            _ = try VoiceGatewayV8Decoder.decode(Data(#"{"op":8,"d":{"heartbeat_interval":0}}"#.utf8))
        }
        #expect(throws: VoiceGatewayV8Error.unsupportedOpcode(99)) {
            _ = try VoiceGatewayV8Decoder.decode(Data(#"{"op":99,"d":{}}"#.utf8))
        }
        let oversized = Data(repeating: 0x20, count: VoiceGatewayV8Decoder.maximumPayloadBytes + 1)
        #expect(throws: VoiceGatewayV8Error.payloadTooLarge) {
            _ = try VoiceGatewayV8Decoder.decode(oversized)
        }
        #expect(throws: VoiceGatewayV8Error.fieldTooLong("token")) {
            _ = try VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "bot",
                sessionID: "session",
                token: String(repeating: "x", count: 4_097)
            )
        }
    }

    @Test("sensitive descriptions are always redacted")
    func redaction() throws {
        let identify = try VoiceGatewayV8Identify(
            serverID: "guild",
            userID: "bot",
            sessionID: "never-print-session",
            token: "never-print-token"
        )
        let resume = try VoiceGatewayV8Resume(
            serverID: "guild",
            sessionID: "never-print-session",
            token: "never-print-token",
            sequenceAcknowledgement: 10
        )
        let session = try VoiceGatewayV8SessionDescription(
            mode: "aead_xchacha20_poly1305_rtpsize",
            secretKey: Array(repeating: 0xAB, count: 32),
            daveProtocolVersion: 0
        )
        let inbound = VoiceGatewayV8Inbound(sequence: 2, payload: .sessionDescription(session))

        var identifyDump = ""
        dump(identify, to: &identifyDump)
        var resumeDump = ""
        dump(resume, to: &resumeDump)
        var sessionDump = ""
        dump(session, to: &sessionDump)
        let mirrorValues = [identify, resume].flatMap { value in
            Mirror(reflecting: value).children.map { String(describing: $0.value) }
        }

        for rendered in [
            String(describing: identify), String(reflecting: identify),
            String(describing: VoiceGatewayV8Outbound.identify(identify)),
            String(reflecting: VoiceGatewayV8Outbound.resume(resume)),
            String(describing: session), String(reflecting: session),
            String(describing: inbound), String(reflecting: inbound),
            identifyDump, resumeDump, sessionDump,
            mirrorValues.joined(separator: " "),
        ] {
            #expect(!rendered.contains("never-print-token"))
            #expect(!rendered.contains("never-print-session"))
            #expect(!rendered.contains("171, 171"))
            #expect(rendered.contains("redacted") || !rendered.contains("token"))
        }
    }

    @Test("bounds DAVE protocol versions while allowing native negotiation values")
    func daveBoundary() throws {
        let identify = try VoiceGatewayV8Identify(
            serverID: "guild",
            userID: "bot",
            sessionID: "session",
            token: "ephemeral-token",
            maxDAVEProtocolVersion: 1
        )
        #expect(identify.maxDAVEProtocolVersion == 1)

        let description = try VoiceGatewayV8SessionDescription(
            mode: "aead_xchacha20_poly1305_rtpsize",
            secretKey: Array(repeating: 0, count: 32),
            daveProtocolVersion: 1
        )
        #expect(description.daveProtocolVersion == 1)

        #expect(throws: VoiceGatewayV8Error.unsupportedDAVEVersion(-1)) {
            _ = try VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "bot",
                sessionID: "session",
                token: "ephemeral-token",
                maxDAVEProtocolVersion: -1
            )
        }
        #expect(throws: VoiceGatewayV8Error.unsupportedDAVEVersion(65_536)) {
            _ = try VoiceGatewayV8SessionDescription(
                mode: "aead_xchacha20_poly1305_rtpsize",
                secretKey: Array(repeating: 0, count: 32),
                daveProtocolVersion: 65_536
            )
        }
    }
}
