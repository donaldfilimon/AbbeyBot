import Foundation
import Testing
@testable import AbbeyCore

// Fixture-driven tests for the video *signaling models only* — Opcode 12
// Video and Opcode 15 Media Sink Wants, SSRC allocation, and participant
// mapping. Fixtures mirror the community Voice Gateway reference
// (docs.discord.food voice-connections). Nothing here exercises capture,
// codecs, RTP, or DAVE video — no such path exists.
@Suite("Discord Voice Gateway v8 video signaling models")
struct VoiceGatewayV8VideoModelsTests {
    // MARK: - Opcode 12 Video

    @Test("outbound Video announcement matches the documented send shape")
    func videoSendJSONShape() throws {
        let stream = try VoiceGatewayV8Stream(
            type: "video",
            rid: "100",
            quality: 100,
            active: true,
            maxBitrate: 9_000_000,
            maxFramerate: 60,
            maxResolution: try VoiceGatewayV8StreamResolution(type: "source", width: 0, height: 0),
            ssrc: 13_960,
            rtxSSRC: 13_961
        )
        let video = try VoiceGatewayV8Video(
            audioSSRC: 13_959,
            videoSSRC: 13_960,
            rtxSSRC: 13_961,
            streams: [stream]
        )
        let data = try JSONEncoder().encode(VoiceGatewayV8Outbound.video(video))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["d"] as? [String: Any])

        #expect(object["op"] as? Int == 12)
        #expect(payload["audio_ssrc"] as? Int == 13_959)
        #expect(payload["video_ssrc"] as? Int == 13_960)
        #expect(payload["rtx_ssrc"] as? Int == 13_961)
        #expect(payload["user_id"] == nil)

        let streams = try #require(payload["streams"] as? [[String: Any]])
        #expect(streams.count == 1)
        let encoded = try #require(streams.first)
        #expect(encoded["type"] as? String == "video")
        #expect(encoded["rid"] as? String == "100")
        #expect(encoded["ssrc"] as? Int == 13_960)
        #expect(encoded["rtx_ssrc"] as? Int == 13_961)
        #expect(encoded["active"] as? Bool == true)
        #expect(encoded["quality"] as? Int == 100)
        #expect(encoded["max_bitrate"] as? Int == 9_000_000)
        #expect(encoded["max_framerate"] as? Int == 60)
        let resolution = try #require(encoded["max_resolution"] as? [String: Any])
        #expect(resolution["type"] as? String == "source")
        #expect(resolution["width"] as? Int == 0)
        #expect(resolution["height"] as? Int == 0)
    }

    @Test("outbound Video clearing announcement zeroes SSRCs and empties streams")
    func videoClearingShape() throws {
        let allocation = try VoiceGatewayV8VideoSSRCAllocation(
            audioSSRC: 12_871,
            streams: [try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100, ssrc: 12_872)]
        )
        let clearing = try allocation.clearingAnnouncement()
        let data = try JSONEncoder().encode(VoiceGatewayV8Outbound.video(clearing))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["d"] as? [String: Any])

        #expect(object["op"] as? Int == 12)
        #expect(payload["video_ssrc"] as? Int == 0)
        #expect(payload["rtx_ssrc"] as? Int == 0)
        #expect((payload["streams"] as? [Any])?.isEmpty == true)
    }

    @Test("outbound Video encoding rejects inbound-only and incomplete shapes")
    func videoOutboundDirectionValidation() throws {
        let stream = try VoiceGatewayV8Stream(
            type: "video",
            rid: "100",
            quality: 100,
            active: true,
            ssrc: 13_960,
            rtxSSRC: 13_961
        )

        // `user_id` is server-owned. Even an otherwise complete payload must
        // not be serialized as an AbbeyBot announcement when it is present.
        let inboundOnly = try VoiceGatewayV8Video(
            audioSSRC: 13_959,
            videoSSRC: 13_960,
            rtxSSRC: 13_961,
            streams: [stream],
            userID: "852892297661906993"
        )
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try JSONEncoder().encode(VoiceGatewayV8Outbound.video(inboundOnly))
        }

        // Discord may omit top-level RTX on receive, but sending an active
        // announcement without the matching nonzero pair is ambiguous.
        let missingTopLevelRTX = try VoiceGatewayV8Video(
            audioSSRC: 13_959,
            videoSSRC: 13_960,
            streams: [stream]
        )
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try JSONEncoder().encode(VoiceGatewayV8Outbound.video(missingTopLevelRTX))
        }

        // A clearing announcement uses an explicit zero RTX, not an omitted
        // value, so the outbound state transition is unambiguous on the wire.
        let incompleteClearing = try VoiceGatewayV8Video(
            audioSSRC: 13_959,
            videoSSRC: 0,
            streams: []
        )
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try JSONEncoder().encode(VoiceGatewayV8Outbound.video(incompleteClearing))
        }
    }

    @Test("decodes the documented server-sent Video fixture")
    func videoReceiveFixture() throws {
        // Verbatim example from the reference (docs.discord.food): server
        // adds user_id and omits the top-level rtx_ssrc.
        let fixture = #"""
        {
          "op": 12,
          "d": {
            "user_id": "852892297661906993",
            "audio_ssrc": 13959,
            "video_ssrc": 13960,
            "streams": [
              {
                "ssrc": 13960,
                "rtx_ssrc": 13961,
                "rid": "100",
                "quality": 100,
                "max_resolution": { "width": 0, "type": "source", "height": 0 },
                "max_framerate": 60,
                "active": true
              }
            ]
          },
          "seq": 6
        }
        """#
        let inbound = try VoiceGatewayV8Decoder.decode(Data(fixture.utf8))
        guard case .video(let video) = inbound.payload else {
            Issue.record("Expected Video")
            return
        }
        #expect(inbound.sequence == 6)
        #expect(video.userID == "852892297661906993")
        #expect(video.audioSSRC == 13_959)
        #expect(video.videoSSRC == 13_960)
        #expect(video.rtxSSRC == nil)
        #expect(video.streams.count == 1)
        let stream = try #require(video.streams.first)
        #expect(stream.ssrc == 13_960)
        #expect(stream.rtxSSRC == 13_961)
        #expect(stream.rid == "100")
        #expect(stream.quality == 100)
        #expect(stream.active == true)
        #expect(stream.maxFramerate == 60)
        #expect(stream.maxResolution?.type == "source")
        // The documented server-sent stream object has no "type" key.
        #expect(stream.type == nil)
    }

    @Test("decodes a Video clearing event with zero SSRC and empty streams")
    func videoReceiveClearing() throws {
        let inbound = try VoiceGatewayV8Decoder.decode(
            Data(#"{"op":12,"d":{"user_id":"852892297661906993","audio_ssrc":13959,"video_ssrc":0,"streams":[]},"seq":7}"#.utf8)
        )
        guard case .video(let video) = inbound.payload else {
            Issue.record("Expected Video")
            return
        }
        #expect(video.videoSSRC == 0)
        #expect(video.streams.isEmpty)
    }

    @Test("tolerates documented and unknown bounded stream types", arguments: ["video", "screen", "test", "future-media-type"])
    func streamTypeTolerance(type: String) throws {
        let stream = try VoiceGatewayV8Stream(type: type, ssrc: 100)
        #expect(stream.type == type)
    }

    @Test("rejects out-of-bounds Video payloads")
    func videoBounds() {
        // Quality is documented as 0-100.
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Stream(type: "video", quality: 101)
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Stream(type: "video", quality: -1)
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Stream(type: "video", maxBitrate: -1)
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Stream(
                type: "video",
                maxBitrate: VoiceGatewayV8VideoBounds.maximumBitrate + 1
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Stream(
                type: "video",
                maxFramerate: VoiceGatewayV8VideoBounds.maximumFramerate + 1
            )
        }
        #expect(throws: VoiceGatewayV8Error.emptyField("type")) {
            _ = try VoiceGatewayV8Stream(type: "")
        }
        #expect(throws: VoiceGatewayV8Error.fieldTooLong("rid")) {
            _ = try VoiceGatewayV8Stream(type: "video", rid: String(repeating: "9", count: 33))
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8StreamResolution(type: "fixed", width: -1, height: 0)
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8StreamResolution(
                type: "fixed",
                width: 0,
                height: VoiceGatewayV8VideoBounds.maximumResolutionDimension + 1
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Video(
                audioSSRC: 1,
                videoSSRC: 2,
                streams: Array(
                    repeating: try VoiceGatewayV8Stream(type: "video", ssrc: 2),
                    count: VoiceGatewayV8VideoBounds.maximumStreams + 1
                )
            )
        }
    }

    @Test("decoder rejects malformed inbound Video payloads")
    func videoDecodeRejections() {
        // Quality above the documented 0-100 range.
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Decoder.decode(
                Data(#"{"op":12,"d":{"audio_ssrc":1,"video_ssrc":2,"streams":[{"type":"video","quality":101}]}}"#.utf8)
            )
        }
        // Missing required SSRC fields.
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Decoder.decode(Data(#"{"op":12,"d":{"streams":[]}}"#.utf8))
        }
        // Control characters in user_id.
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Decoder.decode(
                Data("{\"op\":12,\"d\":{\"user_id\":\"bad\\u0000id\",\"audio_ssrc\":1,\"video_ssrc\":2,\"streams\":[]}}".utf8)
            )
        }
    }

    // MARK: - Opcode 15 Media Sink Wants

    @Test("decodes the documented Media Sink Wants fixture")
    func mediaSinkWantsReceiveFixture() throws {
        // Verbatim example from the reference: SSRC-keyed quality, "any",
        // and fractional pixelCounts.
        let fixture = #"""
        {
          "op": 15,
          "d": {
            "8964": 100,
            "any": 50,
            "pixelCounts": {
              "8964": 1189844.5769597634
            }
          },
          "seq": 8
        }
        """#
        let inbound = try VoiceGatewayV8Decoder.decode(Data(fixture.utf8))
        guard case .mediaSinkWants(let wants) = inbound.payload else {
            Issue.record("Expected Media Sink Wants")
            return
        }
        #expect(inbound.sequence == 8)
        #expect(wants.wants == [8_964: 100])
        #expect(wants.anyQuality == 50)
        #expect(wants.pixelCounts?.count == 1)
        let pixels = try #require(wants.pixelCounts?[8_964])
        #expect(abs(pixels - 1_189_844.5769597634) < 0.0001)
    }

    @Test("outbound Media Sink Wants encodes SSRC keys, any, and pixelCounts")
    func mediaSinkWantsSendShape() throws {
        let wants = try VoiceGatewayV8MediaSinkWants(
            wants: [8_964: 100],
            anyQuality: 50,
            pixelCounts: [8_964: 1_189_844.5]
        )
        let data = try JSONEncoder().encode(VoiceGatewayV8Outbound.mediaSinkWants(wants))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["d"] as? [String: Any])

        #expect(object["op"] as? Int == 15)
        #expect(payload["8964"] as? Int == 100)
        #expect(payload["any"] as? Int == 50)
        let pixelCounts = try #require(payload["pixelCounts"] as? [String: Any])
        #expect(pixelCounts["8964"] as? Double == 1_189_844.5)

        // Round trip through the decoder.
        let envelope = try VoiceGatewayV8Decoder.decode(
            try JSONEncoder().encode(VoiceGatewayV8Outbound.mediaSinkWants(wants))
        )
        guard case .mediaSinkWants(let decoded) = envelope.payload else {
            Issue.record("Expected Media Sink Wants")
            return
        }
        #expect(decoded == wants)
    }

    @Test("rejects out-of-bounds Media Sink Wants payloads")
    func mediaSinkWantsBounds() {
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8MediaSinkWants(wants: [1: 101])
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8MediaSinkWants(wants: [:], anyQuality: -1)
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8MediaSinkWants(wants: [:], pixelCounts: [1: .infinity])
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8MediaSinkWants(wants: [:], pixelCounts: [1: -1])
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            var oversized: [UInt32: Int] = [:]
            for ssrc in 0...UInt32(VoiceGatewayV8VideoBounds.maximumSinkWantEntries) {
                oversized[ssrc] = 0
            }
            _ = try VoiceGatewayV8MediaSinkWants(wants: oversized)
        }
        // Keys other than "any"/"pixelCounts" must be decimal SSRCs.
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Decoder.decode(Data(#"{"op":15,"d":{"not-an-ssrc":100}}"#.utf8))
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Decoder.decode(Data(#"{"op":15,"d":{"pixelCounts":{"not-an-ssrc":1.0}}}"#.utf8))
        }
    }

    @Test("video opcodes are no longer unsupported")
    func videoOpcodesSupported() throws {
        _ = try VoiceGatewayV8Decoder.decode(
            Data(#"{"op":12,"d":{"audio_ssrc":1,"video_ssrc":0,"streams":[]}}"#.utf8)
        )
        _ = try VoiceGatewayV8Decoder.decode(Data(#"{"op":15,"d":{"any":0}}"#.utf8))
        // Undocumented opcodes still fail closed.
        #expect(throws: VoiceGatewayV8Error.unsupportedOpcode(99)) {
            _ = try VoiceGatewayV8Decoder.decode(Data(#"{"op":99,"d":{}}"#.utf8))
        }
    }

    // MARK: - Identify / Ready stream negotiation

    @Test("Identify advertises video support and proposed streams when set")
    func identifyVideoAdvertisement() throws {
        let identify = try VoiceGatewayV8Identify(
            serverID: "guild",
            userID: "bot",
            sessionID: "session",
            token: "ephemeral-token",
            video: true,
            streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100),
                try VoiceGatewayV8Stream(type: "video", rid: "50", quality: 50),
            ]
        )
        let data = try JSONEncoder().encode(VoiceGatewayV8Outbound.identify(identify))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["d"] as? [String: Any])
        #expect(payload["video"] as? Bool == true)
        let streams = try #require(payload["streams"] as? [[String: Any]])
        #expect(streams.count == 2)
        #expect(streams[0]["rid"] as? String == "100")
        #expect(streams[1]["quality"] as? Int == 50)
    }

    @Test("audio-only Identify keeps the historical wire shape")
    func identifyAudioOnlyShape() throws {
        let identify = try VoiceGatewayV8Identify(
            serverID: "guild",
            userID: "bot",
            sessionID: "session",
            token: "ephemeral-token"
        )
        let data = try JSONEncoder().encode(VoiceGatewayV8Outbound.identify(identify))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["d"] as? [String: Any])
        #expect(payload["video"] == nil)
        #expect(payload["streams"] == nil)
    }

    @Test("Identify rejects incoherent video stream advertisements")
    func identifyAdvertisementValidation() throws {
        let proposed = try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100)

        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "bot",
                sessionID: "session",
                token: "token",
                streams: [proposed]
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "bot",
                sessionID: "session",
                token: "token",
                video: false,
                streams: [proposed]
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "bot",
                sessionID: "session",
                token: "token",
                video: true,
                streams: []
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "bot",
                sessionID: "session",
                token: "token",
                video: true,
                streams: [
                    proposed,
                    try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 50),
                ]
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "bot",
                sessionID: "session",
                token: "token",
                video: true,
                streams: [try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 10)]
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "bot",
                sessionID: "session",
                token: "token",
                video: true,
                streams: [try VoiceGatewayV8Stream(rid: "100")]
            )
        }
    }

    @Test("decodes the documented Ready fixture with populated streams")
    func readyStreamsFixture() throws {
        // Verbatim example from the reference.
        let fixture = #"""
        {
          "op": 2,
          "d": {
            "ssrc": 12871,
            "ip": "127.0.0.1",
            "port": 1234,
            "modes": ["aead_aes256_gcm_rtpsize", "aead_xchacha20_poly1305_rtpsize"],
            "experiments": ["fixed_keyframe_interval"],
            "streams": [
              { "type": "video", "ssrc": 12872, "rtx_ssrc": 12873, "rid": "50", "quality": 50, "active": false },
              { "type": "video", "ssrc": 12874, "rtx_ssrc": 12875, "rid": "100", "quality": 100, "active": false }
            ]
          },
          "seq": 2
        }
        """#
        let inbound = try VoiceGatewayV8Decoder.decode(Data(fixture.utf8))
        guard case .ready(let ready) = inbound.payload else {
            Issue.record("Expected Ready")
            return
        }
        #expect(ready.ssrc == 12_871)
        let streams = try #require(ready.streams)
        #expect(streams.count == 2)
        #expect(streams[0].ssrc == 12_872)
        #expect(streams[0].rtxSSRC == 12_873)
        #expect(streams[1].rid == "100")
    }

    @Test("audio-only Ready still decodes with absent streams")
    func readyWithoutStreams() throws {
        let inbound = try VoiceGatewayV8Decoder.decode(
            Data(#"{"op":2,"d":{"ssrc":7,"ip":"203.0.113.4","port":50000,"modes":["aead_xchacha20_poly1305_rtpsize"]},"seq":2}"#.utf8)
        )
        guard case .ready(let ready) = inbound.payload else {
            Issue.record("Expected Ready")
            return
        }
        #expect(ready.streams == nil)
    }

    @Test("Ready rejects duplicate or role-colliding SSRC allocations")
    func readyAllocationValidation() throws {
        func ready(audioSSRC: UInt32 = 1, streams: [VoiceGatewayV8Stream]) throws {
            _ = try VoiceGatewayV8Ready(
                ssrc: audioSSRC,
                ip: "203.0.113.4",
                port: 50_000,
                modes: ["aead_xchacha20_poly1305_rtpsize"],
                streams: streams
            )
        }

        #expect(throws: VoiceGatewayV8Error.invalidReadyPayload) {
            try ready(streams: [])
        }
        #expect(throws: VoiceGatewayV8Error.invalidReadyPayload) {
            try ready(streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 2, rtxSSRC: 3),
                try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 4, rtxSSRC: 5),
            ])
        }
        #expect(throws: VoiceGatewayV8Error.invalidReadyPayload) {
            try ready(streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "50", ssrc: 2, rtxSSRC: 3),
                try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 2, rtxSSRC: 4),
            ])
        }
        #expect(throws: VoiceGatewayV8Error.invalidReadyPayload) {
            try ready(streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "50", ssrc: 2, rtxSSRC: 4),
                try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 3, rtxSSRC: 4),
            ])
        }
        #expect(throws: VoiceGatewayV8Error.invalidReadyPayload) {
            try ready(streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "50", ssrc: 2, rtxSSRC: 3),
                try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 3, rtxSSRC: 4),
            ])
        }
        #expect(throws: VoiceGatewayV8Error.invalidReadyPayload) {
            try ready(streams: [try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 1, rtxSSRC: 2)])
        }
        #expect(throws: VoiceGatewayV8Error.invalidReadyPayload) {
            try ready(streams: [try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 2, rtxSSRC: 1)])
        }
    }

    // MARK: - SSRC allocation

    @Test("derives the RTX SSRC as primary plus one when omitted")
    func rtxDerivation() throws {
        let explicit = try VoiceGatewayV8Stream(type: "video", ssrc: 12_872, rtxSSRC: 12_873)
        #expect(explicit.derivedRTXSSRC == 12_873)

        let derived = try VoiceGatewayV8Stream(type: "video", ssrc: 12_872)
        #expect(derived.derivedRTXSSRC == 12_873)

        let unassigned = try VoiceGatewayV8Stream(type: "video")
        #expect(unassigned.derivedRTXSSRC == nil)

        // Overflow never wraps.
        let boundary = try VoiceGatewayV8Stream(type: "video", ssrc: UInt32.max)
        #expect(boundary.derivedRTXSSRC == nil)
    }

    @Test("allocation announces the highest-quality active layer as primary")
    func allocationAnnouncement() throws {
        let allocation = try VoiceGatewayV8VideoSSRCAllocation(
            audioSSRC: 12_871,
            streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "50", quality: 50, ssrc: 12_872, rtxSSRC: 12_873),
                try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100, ssrc: 12_874),
            ]
        )
        let announcement = try allocation.announcement(activeRIDs: ["50", "100"])
        #expect(announcement.audioSSRC == 12_871)
        #expect(announcement.videoSSRC == 12_874)
        // RTX for the primary layer is derived (12874 + 1) since Ready omitted it.
        #expect(announcement.rtxSSRC == 12_875)
        #expect(announcement.streams.count == 2)
        #expect(announcement.streams.allSatisfy { $0.active == true })

        let partial = try allocation.announcement(activeRIDs: ["50"])
        #expect(partial.videoSSRC == 12_872)
        #expect(partial.rtxSSRC == 12_873)
        #expect(partial.streams.first { $0.rid == "100" }?.active == false)

        // No active layer means there is nothing to announce as primary.
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try allocation.announcement(activeRIDs: [])
        }
    }

    @Test("allocation requires server-assigned SSRCs")
    func allocationRequiresSSRCs() throws {
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8VideoSSRCAllocation(
                audioSSRC: 1,
                streams: [try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100)]
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8VideoSSRCAllocation(audioSSRC: 1, streams: [])
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8VideoSSRCAllocation(
                audioSSRC: 1,
                streams: [
                    try VoiceGatewayV8Stream(type: "video", rid: "50", ssrc: 2, rtxSSRC: 3),
                    try VoiceGatewayV8Stream(type: "video", rid: "50", ssrc: 4, rtxSSRC: 5),
                ]
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8VideoSSRCAllocation(
                audioSSRC: 1,
                streams: [try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 1, rtxSSRC: 2)]
            )
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8VideoSSRCAllocation(
                audioSSRC: 1,
                streams: [
                    try VoiceGatewayV8Stream(type: "video", rid: "50", ssrc: 2, rtxSSRC: 3),
                    try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 3, rtxSSRC: 4),
                ]
            )
        }
    }

    @Test("Video announcements require a coherent selected stream")
    func videoAnnouncementValidation() throws {
        let stream = try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 2, rtxSSRC: 3)
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Video(audioSSRC: 1, videoSSRC: 2, streams: [])
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Video(audioSSRC: 1, videoSSRC: 9, streams: [stream])
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try VoiceGatewayV8Video(audioSSRC: 1, videoSSRC: 2, rtxSSRC: 4, streams: [stream])
        }
    }

    // MARK: - Participant mapping

    @Test("maps user IDs to announced audio, video, and RTX SSRCs")
    func participantMapping() throws {
        var map = VoiceGatewayV8VideoParticipantMap()
        let video = try VoiceGatewayV8Video(
            audioSSRC: 13_959,
            videoSSRC: 13_960,
            streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100, ssrc: 13_960, rtxSSRC: 13_961)
            ],
            userID: "852892297661906993"
        )
        try map.apply(video)

        #expect(map.count == 1)
        #expect(map.userID(forSSRC: 13_959) == "852892297661906993")
        #expect(map.userID(forSSRC: 13_960) == "852892297661906993")
        #expect(map.userID(forSSRC: 13_961) == "852892297661906993")
        #expect(map.userID(forSSRC: 99_999) == nil)
        #expect(map.participant(userID: "852892297661906993")?.videoSSRC == 13_960)

        // Clearing video keeps the audio mapping but drops video SSRCs.
        let cleared = try VoiceGatewayV8Video(
            audioSSRC: 13_959,
            videoSSRC: 0,
            streams: [],
            userID: "852892297661906993"
        )
        try map.apply(cleared)
        #expect(map.userID(forSSRC: 13_959) == "852892297661906993")
        #expect(map.userID(forSSRC: 13_960) == nil)
        #expect(map.userID(forSSRC: 13_961) == nil)

        // Client Disconnect discards the user's SSRC state entirely.
        map.removeParticipant(userID: "852892297661906993")
        #expect(map.count == 0)
        #expect(map.userID(forSSRC: 13_959) == nil)

        // Re-identify requires a full rebuild.
        try map.apply(video)
        map.removeAll()
        #expect(map.count == 0)
    }

    @Test("participant map rejects client-built payloads and enforces bounds")
    func participantMappingBounds() throws {
        var map = VoiceGatewayV8VideoParticipantMap()
        let localAnnouncement = try VoiceGatewayV8Video(audioSSRC: 1, videoSSRC: 0, streams: [])
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            try map.apply(localAnnouncement)
        }
        #expect(map.count == 0)
    }

    @Test("participant SSRC ownership rejects cross-role collisions atomically")
    func participantCollisionAndReplacement() throws {
        func participant(
            userID: String,
            audioSSRC: UInt32,
            videoSSRC: UInt32,
            rtxSSRC: UInt32
        ) throws -> VoiceGatewayV8Video {
            try VoiceGatewayV8Video(
                audioSSRC: audioSSRC,
                videoSSRC: videoSSRC,
                streams: [
                    try VoiceGatewayV8Stream(
                        type: "video",
                        rid: "100",
                        quality: 100,
                        ssrc: videoSSRC,
                        rtxSSRC: rtxSSRC
                    )
                ],
                userID: userID
            )
        }

        var map = VoiceGatewayV8VideoParticipantMap()
        try map.apply(try participant(userID: "a", audioSSRC: 100, videoSSRC: 200, rtxSSRC: 201))

        // Each attempted participant collides with a different role owned by A:
        // audio -> primary, primary -> RTX, and RTX -> audio.
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            try map.apply(try participant(userID: "b", audioSSRC: 200, videoSSRC: 300, rtxSSRC: 301))
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            try map.apply(try participant(userID: "b", audioSSRC: 101, videoSSRC: 201, rtxSSRC: 202))
        }
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            try map.apply(try participant(userID: "b", audioSSRC: 101, videoSSRC: 300, rtxSSRC: 100))
        }
        #expect(map.count == 1)
        #expect(map.userID(forSSRC: 100) == "a")
        #expect(map.userID(forSSRC: 200) == "a")
        #expect(map.userID(forSSRC: 201) == "a")
        #expect(map.participant(userID: "b") == nil)

        try map.apply(try participant(userID: "b", audioSSRC: 101, videoSSRC: 300, rtxSSRC: 301))

        // A rejected replacement must preserve every old claim.
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            try map.apply(try participant(userID: "a", audioSSRC: 300, videoSSRC: 210, rtxSSRC: 211))
        }
        #expect(map.userID(forSSRC: 100) == "a")
        #expect(map.userID(forSSRC: 200) == "a")
        #expect(map.userID(forSSRC: 201) == "a")
        #expect(map.userID(forSSRC: 300) == "b")

        // A successful replacement drops old reverse-index entries and adds
        // the new ones as one state transition.
        try map.apply(try participant(userID: "a", audioSSRC: 110, videoSSRC: 210, rtxSSRC: 211))
        #expect(map.userID(forSSRC: 100) == nil)
        #expect(map.userID(forSSRC: 200) == nil)
        #expect(map.userID(forSSRC: 201) == nil)
        #expect(map.userID(forSSRC: 110) == "a")
        #expect(map.userID(forSSRC: 210) == "a")
        #expect(map.userID(forSSRC: 211) == "a")

        // Removal releases every role so another participant can be assigned
        // the exact former allocation deterministically.
        map.removeParticipant(userID: "b")
        #expect(map.userID(forSSRC: 101) == nil)
        #expect(map.userID(forSSRC: 300) == nil)
        #expect(map.userID(forSSRC: 301) == nil)
        try map.apply(try participant(userID: "c", audioSSRC: 101, videoSSRC: 300, rtxSSRC: 301))
        #expect(map.userID(forSSRC: 101) == "c")
        #expect(map.userID(forSSRC: 300) == "c")
        #expect(map.userID(forSSRC: 301) == "c")
    }

    @Test(
        "the Opcode 12 allocation gate compares both the primary and the RTX SSRC against Ready, so an explicit foreign rtx_ssrc never reaches the wire"
    )
    func videoAnnouncementValidatesRTXSSRCAgainstReady() throws {
        let mode = "aead_xchacha20_poly1305_rtpsize"
        // Ready assigns exactly one stream: primary 45, RTX 46.
        let machine = try establishedMachine(
            mode: mode,
            readyStreams: [
                try VoiceGatewayV8Stream(
                    type: "video",
                    rid: "100",
                    quality: 100,
                    ssrc: 45,
                    rtxSSRC: 46
                )
            ]
        )

        // The server-assigned pair announces normally.
        let assigned = try VoiceGatewayV8Video(
            audioSSRC: 44,
            videoSSRC: 45,
            rtxSSRC: 46,
            streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100, ssrc: 45, rtxSSRC: 46)
            ]
        )
        guard case .video(let outbound) = try machine.videoAnnouncement(assigned) else {
            Issue.record("Expected the assigned announcement to be accepted")
            return
        }
        #expect(outbound.videoSSRC == 45)
        #expect(outbound.rtxSSRC == 46)

        // A Ready-assigned PRIMARY paired with an explicit RTX SSRC the voice
        // server never assigned is rejected before Opcode 12 is emitted. This
        // payload is well-formed on its own terms — `VoiceGatewayV8Video`
        // accepts any self-consistent explicit `rtx_ssrc` — so only the
        // Ready comparison can catch it.
        let foreignRTX = try VoiceGatewayV8Video(
            audioSSRC: 44,
            videoSSRC: 45,
            rtxSSRC: 900,
            streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100, ssrc: 45, rtxSSRC: 900)
            ]
        )
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try machine.videoAnnouncement(foreignRTX)
        }

        // Same smuggling attempt with only the per-stream RTX diverging while
        // the top-level pair stays the assigned one.
        let foreignStreamRTX = try VoiceGatewayV8Video(
            audioSSRC: 44,
            videoSSRC: 45,
            rtxSSRC: nil,
            streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100, ssrc: 45, rtxSSRC: 901)
            ]
        )
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try machine.videoAnnouncement(foreignStreamRTX)
        }

        // A second Ready stream whose RTX SSRC is derived (ssrc + 1) rather
        // than explicit is matched by the same rule: 47/48 is assigned, 47/99
        // is not.
        let derived = try establishedMachine(
            mode: mode,
            readyStreams: [
                try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100, ssrc: 47)
            ]
        )
        let derivedMatch = try VoiceGatewayV8Video(
            audioSSRC: 44,
            videoSSRC: 47,
            rtxSSRC: 48,
            streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100, ssrc: 47, rtxSSRC: 48)
            ]
        )
        _ = try derived.videoAnnouncement(derivedMatch)
        let derivedMismatch = try VoiceGatewayV8Video(
            audioSSRC: 44,
            videoSSRC: 47,
            rtxSSRC: 99,
            streams: [
                try VoiceGatewayV8Stream(type: "video", rid: "100", quality: 100, ssrc: 47, rtxSSRC: 99)
            ]
        )
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            _ = try derived.videoAnnouncement(derivedMismatch)
        }

        // Clearing video still needs no stream allocation.
        let clearing = try VoiceGatewayV8Video(audioSSRC: 44, videoSSRC: 0, rtxSSRC: 0, streams: [])
        _ = try machine.videoAnnouncement(clearing)
    }

    /// Drives a machine to `.established` with the given Ready stream
    /// allocation so Opcode 12 validation can be exercised directly.
    private func establishedMachine(
        mode: String,
        readyStreams: [VoiceGatewayV8Stream]
    ) throws -> VoiceGatewayV8StateMachine {
        let identity = try VoiceGatewayV8Identify(
            serverID: "guild",
            userID: "bot",
            sessionID: "session",
            token: "ephemeral-token",
            video: true,
            streams: [try VoiceGatewayV8Stream(type: "video", rid: "100")]
        )
        var machine = VoiceGatewayV8StateMachine(identity: identity)
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
                    ssrc: 44,
                    ip: "203.0.113.4",
                    port: 50_000,
                    modes: [mode],
                    streams: readyStreams
                ))
            ),
            nowMilliseconds: 1
        )
        _ = try machine.selectProtocol(address: "198.51.100.40", port: 63_040, mode: mode)
        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 3,
                payload: .sessionDescription(try VoiceGatewayV8SessionDescription(
                    mode: mode,
                    secretKey: [UInt8](repeating: 7, count: 32),
                    daveProtocolVersion: 0
                ))
            ),
            nowMilliseconds: 2
        )
        #expect(machine.phase == .established)
        return machine
    }

    @Test("state machine applies video ownership and disconnect teardown")
    func stateMachineParticipantOwnershipLifecycle() throws {
        let identity = try VoiceGatewayV8Identify(
            serverID: "guild",
            userID: "bot",
            sessionID: "session",
            token: "ephemeral-token"
        )
        var machine = VoiceGatewayV8StateMachine(identity: identity)
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
                    ssrc: 1,
                    ip: "203.0.113.4",
                    port: 50_000,
                    modes: ["aead_xchacha20_poly1305_rtpsize"]
                ))
            ),
            nowMilliseconds: 1
        )

        let first = try VoiceGatewayV8Video(
            audioSSRC: 100,
            videoSSRC: 200,
            streams: [try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 200, rtxSSRC: 201)],
            userID: "a"
        )
        try machine.receive(
            VoiceGatewayV8Inbound(sequence: 3, payload: .video(first)),
            nowMilliseconds: 2
        )
        #expect(machine.videoParticipants.userID(forSSRC: 201) == "a")

        let colliding = try VoiceGatewayV8Video(
            audioSSRC: 101,
            videoSSRC: 201,
            streams: [try VoiceGatewayV8Stream(type: "video", rid: "100", ssrc: 201, rtxSSRC: 202)],
            userID: "b"
        )
        #expect(throws: VoiceGatewayV8Error.malformedPayload) {
            try machine.receive(
                VoiceGatewayV8Inbound(sequence: 4, payload: .video(colliding)),
                nowMilliseconds: 3
            )
        }
        #expect(machine.lastReceivedSequence == 3)
        #expect(machine.videoParticipants.count == 1)
        #expect(machine.videoParticipants.userID(forSSRC: 201) == "a")

        try machine.receive(
            VoiceGatewayV8Inbound(
                sequence: 4,
                payload: .clientDisconnect(try VoiceGatewayV8ClientDisconnect(userID: "a"))
            ),
            nowMilliseconds: 4
        )
        #expect(machine.videoParticipants.count == 0)
        #expect(machine.videoParticipants.userID(forSSRC: 201) == nil)
    }

    @Test("stream objects without a type key decode, matching the server example")
    func streamTypeOptionality() throws {
        // The reference's Stream Structure table lists `type`, but the
        // documented server-sent Video example omits it; the wire example is
        // authoritative, so type-less streams must decode.
        let inbound = try VoiceGatewayV8Decoder.decode(
            Data(#"{"op":12,"d":{"user_id":"852892297661906993","audio_ssrc":1,"video_ssrc":2,"streams":[{"ssrc":2,"rid":"100"}]}}"#.utf8)
        )
        guard case .video(let video) = inbound.payload else {
            Issue.record("Expected Video")
            return
        }
        #expect(video.streams.first?.type == nil)
        #expect(video.streams.first?.ssrc == 2)
    }
}
