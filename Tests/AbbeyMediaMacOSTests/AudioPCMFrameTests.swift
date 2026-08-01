import Testing
@testable import AbbeyMediaMacOS

@Suite("Discord PCM frame")
struct AudioPCMFrameTests {
    @Test("frame accepts only 48 kHz stereo 20 ms payloads")
    func rejectsWrongFormats() {
        let exact = Array(repeating: Float.zero, count: AudioPCMFrame.interleavedSampleCount)
        #expect(throws: AudioPCMFrameError.unsupportedSampleRate(44_100)) {
            try AudioPCMFrame(float32: exact, sampleRate: 44_100)
        }
        #expect(throws: AudioPCMFrameError.unsupportedChannelCount(1)) {
            try AudioPCMFrame(float32: exact, channelCount: 1)
        }
        #expect(
            throws: AudioPCMFrameError.incorrectSampleCount(actual: 1_918, expected: 1_920)
        ) {
            try AudioPCMFrame(float32: Array(exact.dropLast(2)))
        }
    }

    @Test("Float32 and Int16 conversion preserves owned exact frames")
    func storageConversion() throws {
        var samples = Array(repeating: Float.zero, count: AudioPCMFrame.interleavedSampleCount)
        samples[0...5] = [-1, -0.5, 0, 0.5, 1, .nan]
        let frame = try AudioPCMFrame(float32: samples)
        #expect(Array(frame.int16Samples.prefix(6)) == [Int16.min, -16_384, 0, 16_384, Int16.max, 0])
        #expect(frame.frameCount == 960)
    }
}
