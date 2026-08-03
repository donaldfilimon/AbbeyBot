import AbbeyMediaMacOS
import CoreGraphics
import CoreVideo
import Foundation

/// Converts an adapter-owned BGRA frame into a `CGImage` for LOCAL in-app preview.
/// This is a pure display conversion: nothing is encoded, persisted, or transmitted,
/// and there is no Discord video path behind it.
enum VideoFramePreviewRenderer {
    /// Returns `nil` for any frame that is not 32-bit BGRA — the only format the
    /// capture adapter produces — instead of guessing at a decode.
    static func makeCGImage(from frame: OwnedVideoFrame) -> CGImage? {
        guard frame.pixelFormat == kCVPixelFormatType_32BGRA else { return nil }
        guard let provider = CGDataProvider(data: frame.bytes as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
