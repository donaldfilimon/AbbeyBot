import CoreVideo
import Foundation
import Testing
@testable import AbbeyMediaMacOS

@Suite("VideoToolbox H.264 codec")
struct H264VideoToolboxCodecTests {
    @Test("BGRA capture becomes Annex-B H.264 and decodes into an owned BGRA frame")
    func encodeDecodeRoundTrip() async throws {
        let width = 64
        let height = 64
        let stride = width * 4
        var pixels = Data(count: stride * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    bytes[offset] = UInt8((x * 4) & 0xff)
                    bytes[offset + 1] = UInt8((y * 4) & 0xff)
                    bytes[offset + 2] = 180
                    bytes[offset + 3] = 255
                }
            }
        }
        let source = try OwnedVideoFrame(
            width: width,
            height: height,
            bytesPerRow: stride,
            presentationTimeNanoseconds: 1_000_000_000,
            bytes: pixels
        )
        let configuration = try H264VideoToolboxEncoder.Configuration(
            width: width,
            height: height,
            framesPerSecond: 30,
            averageBitRate: 300_000,
            maximumKeyFrameInterval: 30
        )
        let encoder = H264VideoToolboxEncoder(configuration: configuration)
        let accessUnit = try await encoder.encode(source, forceKeyFrame: true)
        #expect(accessUnit.isKeyFrame)
        #expect(accessUnit.annexB.starts(with: [0, 0, 0, 1]))
        #expect(accessUnit.annexB.count < 512 * 1_024)

        let decoder = H264VideoToolboxDecoder()
        let decoded = try await decoder.decode(accessUnit)
        #expect(decoded.width == width)
        #expect(decoded.height == height)
        #expect(decoded.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(decoded.bytes.count == decoded.bytesPerRow * height)

        await encoder.invalidate()
        await decoder.invalidate()
    }

    @Test("encoder bounds reject oversized video before allocating native state")
    func invalidGeometryFailsClosed() {
        #expect(throws: H264VideoToolboxError.invalidGeometry) {
            _ = try H264VideoToolboxEncoder.Configuration(width: 8_192, height: 4_320)
        }
    }

    @Test("decoder rejects encoded access units above its allocation budget")
    func oversizedAccessUnitFailsClosed() async {
        var bytes = Data([0, 0, 0, 1, 0x65])
        bytes.append(Data(repeating: 0, count: 4 * 1_024 * 1_024))
        let decoder = H264VideoToolboxDecoder()
        await #expect(throws: H264VideoToolboxError.accessUnitTooLarge) {
            _ = try await decoder.decode(.init(
                annexB: bytes,
                presentationTimeNanoseconds: 0,
                isKeyFrame: false
            ))
        }
    }

    @Test("decoder rejects forbidden-bit and RTP-only NAL headers before native allocation")
    func invalidNALHeadersFailClosed() async {
        let decoder = H264VideoToolboxDecoder()
        for header: UInt8 in [0xe5, 0x7c] {
            await #expect(throws: H264VideoToolboxError.malformedAccessUnit) {
                _ = try await decoder.decode(.init(
                    annexB: Data([0, 0, 0, 1, header, 1]),
                    presentationTimeNanoseconds: 0,
                    isKeyFrame: false
                ))
            }
        }
        await #expect(throws: H264VideoToolboxError.malformedAccessUnit) {
            _ = try await decoder.decode(.init(
                // SEI is a valid NAL, but it cannot produce a decoded frame.
                // Reject metadata-only access units instead of suspending a
                // continuation for a callback VideoToolbox need not emit.
                annexB: Data([0, 0, 0, 1, 0x06, 1]),
                presentationTimeNanoseconds: 0,
                isKeyFrame: false
            ))
        }
    }

    @Test("timestamps that cannot fit CoreMedia fail before native allocation")
    func invalidTimestampFailsClosed() async throws {
        let width = 16
        let height = 16
        let frame = try OwnedVideoFrame(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            presentationTimeNanoseconds: .max,
            bytes: Data(repeating: 0, count: width * height * 4)
        )
        let encoder = H264VideoToolboxEncoder(configuration: try .init(width: width, height: height))
        await #expect(throws: H264VideoToolboxError.invalidTimestamp) {
            _ = try await encoder.encode(frame)
        }
    }
}
