import Foundation
import Testing
@testable import AbbeyMediaNative

@Suite("Opus 20 ms codec")
struct Opus20msCodecTests {
    @Test("generated stereo frame round trips to one 20 ms frame")
    func generatedRoundTrip() async throws {
        let codec = try Opus20msCodec()
        let pcm = (0..<Opus20msCodec.samplesPerChannel).flatMap { sample -> [Int16] in
            let phase = 2 * Double.pi * 440 * Double(sample) / Double(Opus20msCodec.sampleRate)
            let value = Int16((sin(phase) * 12_000).rounded())
            return [value, value]
        }
        let packet = try await codec.encode(pcm)
        let decoded = try await codec.decode(packet)
        #expect(!packet.isEmpty)
        #expect(decoded.count == Opus20msCodec.interleavedSampleCount)
        #expect(decoded.contains { abs(Int($0)) > 100 })
    }

    @Test("silence and packet-loss concealment remain bounded")
    func silenceAndPLC() async throws {
        let codec = try Opus20msCodec()
        let silence = [Int16](repeating: 0, count: Opus20msCodec.interleavedSampleCount)
        let packet = try await codec.encode(silence)
        let decoded = try await codec.decode(packet)
        let concealed = try await codec.decodePacketLoss()
        #expect(!packet.isEmpty)
        #expect(decoded.count == Opus20msCodec.interleavedSampleCount)
        #expect(concealed.count == Opus20msCodec.interleavedSampleCount)
    }

    @Test("invalid PCM and packet lengths are rejected before native calls")
    func invalidLengths() async throws {
        let codec = try Opus20msCodec()
        await #expect(throws: NativeMediaError.invalidFrameLength(expected: 1_920, actual: 1)) {
            try await codec.encode([0])
        }
        await #expect(throws: NativeMediaError.invalidPacketLength(actual: 0)) {
            try await codec.decode([])
        }
        await #expect(throws: NativeMediaError.invalidPacketLength(actual: 1_276)) {
            try await codec.decode([UInt8](repeating: 0, count: 1_276))
        }
    }
}
