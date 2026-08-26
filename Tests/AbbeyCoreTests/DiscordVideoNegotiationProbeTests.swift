import Foundation
import Testing
@testable import AbbeyCore

@Suite("Discord video negotiation metadata probe")
struct DiscordVideoNegotiationProbeTests {
    @Test func recordsOnlyBoundedCodecMetadata() async {
        let probe = DiscordVideoNegotiationProbe(maximumObservations: 2)
        await probe.observe(Data(#"{"op":2,"d":{"token":"never-retain","user_id":"123","codecs":[{"name":"H264","payload_type":101}]}}"#.utf8), daveProtocolVersion: 1)
        let values = await probe.observations()
        #expect(values.count == 1)
        #expect(values[0].opcode == 2)
        #expect(values[0].fieldPath == "d.codecs[]")
        #expect(values[0].codecLabel == "H264")
        #expect(values[0].payloadType == 101)
        #expect(values[0].daveProtocolVersion == 1)
        let encoded = String(decoding: try! JSONEncoder().encode(values), as: UTF8.self)
        #expect(!encoded.contains("never-retain"))
        #expect(!encoded.contains("123"))
    }

    @Test func arbitraryStringsAndInvalidPayloadTypesAreIgnored() async {
        let probe = DiscordVideoNegotiationProbe()
        await probe.observe(Data(#"{"op":12,"d":{"name":"private-window-title","payload_type":999}}"#.utf8), daveProtocolVersion: 1)
        await probe.observe(Data(#"{"op":12,"d":{"codec":"H264","payload_type":999}}"#.utf8), daveProtocolVersion: 1)
        await probe.observe(Data(#"{"op":12,"d":{"codec":"H264","payload_type":101.5}}"#.utf8), daveProtocolVersion: 1)
        await probe.observe(Data(#"{"op":12,"d":{"codec":"H264","payload_type":true}}"#.utf8), daveProtocolVersion: 1)
        #expect(await probe.observations().isEmpty)
    }

    @Test func remoteKeysCannotEnterReceiptAndSemanticDuplicatesCollapse() async throws {
        let probe = DiscordVideoNegotiationProbe()
        let payload = Data(
            #"{"op":12,"d":{"participant-secret":{"codec":"H264","payload_type":101}}}"#.utf8
        )
        await probe.observe(payload, daveProtocolVersion: 1)
        await probe.observe(payload, daveProtocolVersion: 1)
        let observations = await probe.observations()
        #expect(observations.count == 1)
        #expect(observations[0].fieldPath == "d.other")
        let receipt = String(decoding: try JSONEncoder().encode(observations), as: UTF8.self)
        #expect(!receipt.contains("participant-secret"))
    }

    @Test func deeplyNestedRemoteMetadataCannotExhaustTheScanner() async throws {
        var nested: Any = ["codec": "H264", "payload_type": 101]
        for _ in 0..<40 { nested = ["other": nested] }
        let payload = try JSONSerialization.data(withJSONObject: ["op": 12, "d": nested])
        let probe = DiscordVideoNegotiationProbe()
        await probe.observe(payload, daveProtocolVersion: 1)
        #expect(await probe.observations().isEmpty)
    }
}
