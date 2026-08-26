import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private enum H264VideoToolboxLimits {
    static let maximumAccessUnitBytes = 4 * 1_024 * 1_024
    static let maximumNALUnits = 256
}

public enum H264VideoToolboxError: Error, Equatable, Sendable {
    case invalidGeometry
    case invalidTimestamp
    case accessUnitTooLarge
    case unsupportedPixelFormat
    case pixelBufferCreation(OSStatus)
    case encoderCreation(OSStatus)
    case encoderConfiguration(OSStatus)
    case encodeFailed(OSStatus)
    case encodedSampleMissing
    case malformedAccessUnit
    case parameterSetsMissing
    case formatDescriptionFailed(OSStatus)
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case decoderCreation(OSStatus)
    case decodeFailed(OSStatus)
    case decodedFrameMissing
}

/// One H.264 access unit produced by VideoToolbox. Storage is owned and uses
/// Annex-B start codes so it can cross the DAVE codec-aware boundary without
/// retaining a CMSampleBuffer or capture surface.
public struct H264EncodedAccessUnit: Equatable, Sendable {
    public let annexB: Data
    public let presentationTimeNanoseconds: UInt64
    public let isKeyFrame: Bool

    public init(annexB: Data, presentationTimeNanoseconds: UInt64, isKeyFrame: Bool) {
        self.annexB = annexB
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.isKeyFrame = isKeyFrame
    }
}

private final class H264EncodePromise: @unchecked Sendable {
    let continuation: CheckedContinuation<H264EncodedAccessUnit, any Error>
    init(_ continuation: CheckedContinuation<H264EncodedAccessUnit, any Error>) {
        self.continuation = continuation
    }
}

private final class H264DecodePromise: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OwnedVideoFrame, any Error>?

    init(_ continuation: CheckedContinuation<OwnedVideoFrame, any Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<OwnedVideoFrame, any Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }
}

/// Hardware-backed, real-time H.264 encoder. The actor serializes
/// VTCompressionSession access, bounds the dimensions/bitrate, disables frame
/// reordering, and deep-copies every output before it crosses the callback.
public actor H264VideoToolboxEncoder {
    public struct Configuration: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var framesPerSecond: Int
        public var averageBitRate: Int
        public var maximumKeyFrameInterval: Int

        public init(
            width: Int,
            height: Int,
            framesPerSecond: Int = 30,
            averageBitRate: Int = 2_500_000,
            maximumKeyFrameInterval: Int = 60
        ) throws {
            guard (16...3_840).contains(width), (16...2_160).contains(height),
                  (1...60).contains(framesPerSecond),
                  (64_000...20_000_000).contains(averageBitRate),
                  (1...600).contains(maximumKeyFrameInterval)
            else { throw H264VideoToolboxError.invalidGeometry }
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            self.averageBitRate = averageBitRate
            self.maximumKeyFrameInterval = maximumKeyFrameInterval
        }
    }

    private let configuration: Configuration
    private var session: VTCompressionSession?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    isolated deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    public func encode(_ frame: OwnedVideoFrame, forceKeyFrame: Bool = false) async throws
        -> H264EncodedAccessUnit
    {
        guard frame.width == configuration.width, frame.height == configuration.height else {
            throw H264VideoToolboxError.invalidGeometry
        }
        guard frame.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw H264VideoToolboxError.unsupportedPixelFormat
        }
        guard frame.presentationTimeNanoseconds <= UInt64(Int64.max) else {
            throw H264VideoToolboxError.invalidTimestamp
        }
        let pixelBuffer = try Self.makePixelBuffer(frame)
        let compressionSession = try configuredSession()
        let time = CMTime(value: CMTimeValue(frame.presentationTimeNanoseconds), timescale: 1_000_000_000)
        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        let properties: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        return try await withCheckedThrowingContinuation { continuation in
            let promise = H264EncodePromise(continuation)
            let pointer = Unmanaged.passRetained(promise).toOpaque()
            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                compressionSession,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: time,
                duration: duration,
                frameProperties: properties,
                sourceFrameRefcon: pointer,
                infoFlagsOut: &flags
            )
            guard status == noErr else {
                Unmanaged<H264EncodePromise>.fromOpaque(pointer).release()
                continuation.resume(throwing: H264VideoToolboxError.encodeFailed(status))
                return
            }
        }
    }

    public func finish() throws {
        guard let session else { return }
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else { throw H264VideoToolboxError.encodeFailed(status) }
    }

    public func invalidate() {
        if let session {
            // Apple documents CompleteFrames(.invalid) as forcing every pending
            // frame to be emitted before it returns. Drain callbacks before
            // invalidating so a suspended encode continuation is never stranded.
            _ = VTCompressionSessionCompleteFrames(
                session,
                untilPresentationTimeStamp: .invalid
            )
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func configuredSession() throws -> VTCompressionSession {
        if let session { return session }
        var created: VTCompressionSession?
        let attributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: configuration.width,
            kCVPixelBufferHeightKey: configuration.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attributes,
            compressedDataAllocator: nil,
            outputCallback: h264CompressionOutputCallback,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw H264VideoToolboxError.encoderCreation(status)
        }
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, configuration.framesPerSecond as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, configuration.averageBitRate as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, configuration.maximumKeyFrameInterval as CFNumber),
        ]
        for (key, value) in settings {
            let settingStatus = VTSessionSetProperty(created, key: key, value: value)
            guard settingStatus == noErr else {
                VTCompressionSessionInvalidate(created)
                throw H264VideoToolboxError.encoderConfiguration(settingStatus)
            }
        }
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(created)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(created)
            throw H264VideoToolboxError.encoderConfiguration(prepareStatus)
        }
        session = created
        return created
    }

    private static func makePixelBuffer(_ frame: OwnedVideoFrame) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frame.width,
            frame.height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else {
            throw H264VideoToolboxError.pixelBufferCreation(status)
        }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let destination = CVPixelBufferGetBaseAddress(output) else {
            throw H264VideoToolboxError.pixelBufferCreation(kCVReturnInvalidArgument)
        }
        let destinationStride = CVPixelBufferGetBytesPerRow(output)
        let visibleRowBytes = frame.width * 4
        // CVPixelBuffer row alignment may exceed the captured frame's stride.
        // Clear destination padding so the encoder never observes stale
        // allocator bytes outside the visible BGRA pixels.
        memset(destination, 0, destinationStride * frame.height)
        frame.bytes.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<frame.height {
                memcpy(
                    destination.advanced(by: row * destinationStride),
                    sourceBase.advanced(by: row * frame.bytesPerRow),
                    visibleRowBytes
                )
            }
        }
        return output
    }
}

/// Hardware-backed H.264 decoder. Parameter sets are accepted only from the
/// current Annex-B access unit, output is always deep-copied BGRA, and session
/// state can be invalidated immediately by a consent/source kill switch.
public actor H264VideoToolboxDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSetDigest: Data?

    public init() {}

    isolated deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    public func decode(_ encoded: H264EncodedAccessUnit) async throws -> OwnedVideoFrame {
        guard encoded.annexB.count <= H264VideoToolboxLimits.maximumAccessUnitBytes else {
            throw H264VideoToolboxError.accessUnitTooLarge
        }
        guard encoded.presentationTimeNanoseconds <= UInt64(Int64.max) else {
            throw H264VideoToolboxError.invalidTimestamp
        }
        let units = try H264AnnexB.units(encoded.annexB)
        let sps = units.first { ($0.first ?? 0) & 0x1f == 7 }
        let pps = units.first { ($0.first ?? 0) & 0x1f == 8 }
        if let sps, let pps {
            try configureIfNeeded(sps: sps, pps: pps)
        }
        let samples = units.filter { unit in
            let type = (unit.first ?? 0) & 0x1f
            return type != 7 && type != 8 && type != 9
        }
        guard samples.contains(where: { (1...5).contains(($0.first ?? 0) & 0x1f) }) else {
            throw H264VideoToolboxError.malformedAccessUnit
        }
        guard let session, let formatDescription else {
            throw H264VideoToolboxError.parameterSetsMissing
        }
        let avcc = samples.reduce(into: Data()) { result, unit in
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(unit)
        }
        let sampleBuffer = try Self.makeSampleBuffer(
            avcc: avcc,
            format: formatDescription,
            presentationTimeNanoseconds: encoded.presentationTimeNanoseconds
        )
        return try await withCheckedThrowingContinuation { continuation in
            let promise = H264DecodePromise(continuation)
            // Decode is deliberately synchronous (no async/temporal flags),
            // so the stack-owned promise remains alive through any callback.
            // A dropped/no-output frame may produce no callback at all; the
            // pending check below closes that otherwise-stranded continuation.
            let pointer = Unmanaged.passUnretained(promise).toOpaque()
            var flags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                // With both asynchronous and temporal-processing flags clear,
                // VideoToolbox guarantees the callback runs before this call
                // returns. Invalidation therefore cannot strand the continuation.
                flags: [],
                frameRefcon: pointer,
                infoFlagsOut: &flags
            )
            guard status == noErr else {
                promise.resume(with: .failure(H264VideoToolboxError.decodeFailed(status)))
                return
            }
            if promise.isPending {
                promise.resume(with: .failure(H264VideoToolboxError.decodedFrameMissing))
            }
        }
    }

    public func invalidate() {
        if let session {
            _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        parameterSetDigest = nil
    }

    private func configureIfNeeded(sps: Data, pps: Data) throws {
        // Length framing prevents ambiguous SPS/PPS concatenations from being
        // mistaken for the same parameter-set identity.
        var combined = Data()
        var spsLength = UInt32(sps.count).bigEndian
        var ppsLength = UInt32(pps.count).bigEndian
        withUnsafeBytes(of: &spsLength) { combined.append(contentsOf: $0) }
        combined.append(sps)
        withUnsafeBytes(of: &ppsLength) { combined.append(contentsOf: $0) }
        combined.append(pps)
        guard combined != parameterSetDigest else { return }
        invalidate()
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
        guard status == noErr, let format else {
            throw H264VideoToolboxError.formatDescriptionFailed(status)
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard (16...3_840).contains(Int(dimensions.width)),
              (16...2_160).contains(Int(dimensions.height))
        else { throw H264VideoToolboxError.invalidGeometry }
        var created: VTDecompressionSession?
        let attributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264DecompressionOutputCallback,
            decompressionOutputRefCon: nil
        )
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: &record,
            decompressionSessionOut: &created
        )
        guard createStatus == noErr, let created else {
            throw H264VideoToolboxError.decoderCreation(createStatus)
        }
        self.formatDescription = format
        self.session = created
        parameterSetDigest = combined
    }

    private static func makeSampleBuffer(
        avcc: Data,
        format: CMVideoFormatDescription,
        presentationTimeNanoseconds: UInt64
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard blockStatus == noErr, let block else {
            throw H264VideoToolboxError.blockBufferFailed(blockStatus)
        }
        let replaceStatus = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard replaceStatus == noErr else {
            throw H264VideoToolboxError.blockBufferFailed(replaceStatus)
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(presentationTimeNanoseconds),
                timescale: 1_000_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var size = avcc.count
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else {
            throw H264VideoToolboxError.sampleBufferFailed(sampleStatus)
        }
        return sample
    }
}

private enum H264AnnexB {
    static func units(_ data: Data) throws -> [Data] {
        guard data.count <= H264VideoToolboxLimits.maximumAccessUnitBytes else {
            throw H264VideoToolboxError.accessUnitTooLarge
        }
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { throw H264VideoToolboxError.malformedAccessUnit }
        var starts: [(Int, Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index...index + 3].elementsEqual([0, 0, 0, 1]) {
                starts.append((index, 4)); index += 4
            } else if bytes[index...index + 2].elementsEqual([0, 0, 1]) {
                starts.append((index, 3)); index += 3
            } else { index += 1 }
            guard starts.count <= H264VideoToolboxLimits.maximumNALUnits else {
                throw H264VideoToolboxError.accessUnitTooLarge
            }
        }
        guard starts.first?.0 == 0, !starts.isEmpty else {
            throw H264VideoToolboxError.malformedAccessUnit
        }
        return try starts.indices.map { position in
            let begin = starts[position].0 + starts[position].1
            let end = position + 1 < starts.count ? starts[position + 1].0 : bytes.count
            guard begin < end else { throw H264VideoToolboxError.malformedAccessUnit }
            let unit = Data(bytes[begin..<end])
            guard let header = unit.first,
                  header & 0x80 == 0,
                  (1...23).contains(header & 0x1f)
            else { throw H264VideoToolboxError.malformedAccessUnit }
            return unit
        }
    }
}

private let h264CompressionOutputCallback: VTCompressionOutputCallback = {
    _, sourceFrameRefCon, status, _, sampleBuffer in
    guard let sourceFrameRefCon else { return }
    let promise = Unmanaged<H264EncodePromise>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
    guard status == noErr else {
        promise.continuation.resume(throwing: H264VideoToolboxError.encodeFailed(status))
        return
    }
    guard let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
        promise.continuation.resume(throwing: H264VideoToolboxError.encodedSampleMissing)
        return
    }
    do {
        promise.continuation.resume(returning: try h264AnnexBAccessUnit(sampleBuffer))
    } catch {
        promise.continuation.resume(throwing: error)
    }
}

private func h264AnnexBAccessUnit(_ sample: CMSampleBuffer) throws -> H264EncodedAccessUnit {
    guard let format = CMSampleBufferGetFormatDescription(sample),
          let block = CMSampleBufferGetDataBuffer(sample)
    else { throw H264VideoToolboxError.encodedSampleMissing }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
    let first = (attachments as? [[CFString: Any]])?.first
    let isKeyFrame = (first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    var parameterSetCount = 0
    var nalUnitHeaderLength: Int32 = 0
    let formatStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format,
        parameterSetIndex: 0,
        parameterSetPointerOut: nil,
        parameterSetSizeOut: nil,
        parameterSetCountOut: &parameterSetCount,
        nalUnitHeaderLengthOut: &nalUnitHeaderLength
    )
    guard formatStatus == noErr,
          parameterSetCount > 0,
          parameterSetCount <= H264VideoToolboxLimits.maximumNALUnits,
          (1...4).contains(nalUnitHeaderLength)
    else { throw H264VideoToolboxError.malformedAccessUnit }
    var output = Data()
    var nalUnitCount = 0
    if isKeyFrame {
        var sawSPS = false
        var sawPPS = false
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else {
                throw H264VideoToolboxError.parameterSetsMissing
            }
            let header = pointer.pointee
            let type = header & 0x1f
            guard header & 0x80 == 0, (1...23).contains(type) else {
                throw H264VideoToolboxError.malformedAccessUnit
            }
            sawSPS = sawSPS || type == 7
            sawPPS = sawPPS || type == 8
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(pointer, count: size)
            nalUnitCount += 1
            guard output.count <= H264VideoToolboxLimits.maximumAccessUnitBytes else {
                throw H264VideoToolboxError.accessUnitTooLarge
            }
        }
        guard sawSPS, sawPPS else { throw H264VideoToolboxError.parameterSetsMissing }
    }
    let byteCount = CMBlockBufferGetDataLength(block)
    guard byteCount > 0 else { throw H264VideoToolboxError.encodedSampleMissing }
    var bytes = Data(count: byteCount)
    let copyStatus = bytes.withUnsafeMutableBytes { destination in
        CMBlockBufferCopyDataBytes(
            block,
            atOffset: 0,
            dataLength: byteCount,
            destination: destination.baseAddress!
        )
    }
    guard copyStatus == noErr else { throw H264VideoToolboxError.blockBufferFailed(copyStatus) }
    var cursor = 0
    let lengthFieldBytes = Int(nalUnitHeaderLength)
    while cursor + lengthFieldBytes <= bytes.count {
        let length = bytes[cursor..<(cursor + lengthFieldBytes)]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        cursor += lengthFieldBytes
        guard length > 0, Int(length) <= bytes.count - cursor else {
            throw H264VideoToolboxError.malformedAccessUnit
        }
        let header = bytes[cursor]
        guard header & 0x80 == 0, (1...23).contains(header & 0x1f) else {
            throw H264VideoToolboxError.malformedAccessUnit
        }
        output.append(contentsOf: [0, 0, 0, 1])
        output.append(bytes[cursor..<(cursor + Int(length))])
        cursor += Int(length)
        nalUnitCount += 1
        guard nalUnitCount <= H264VideoToolboxLimits.maximumNALUnits,
              output.count <= H264VideoToolboxLimits.maximumAccessUnitBytes
        else {
            throw H264VideoToolboxError.accessUnitTooLarge
        }
    }
    guard cursor == bytes.count, !output.isEmpty else {
        throw H264VideoToolboxError.malformedAccessUnit
    }
    let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
    let nanoseconds = seconds.isFinite && seconds > 0
        ? UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
        : 0
    return H264EncodedAccessUnit(
        annexB: output,
        presentationTimeNanoseconds: nanoseconds,
        isKeyFrame: isKeyFrame
    )
}

private let h264DecompressionOutputCallback: VTDecompressionOutputCallback = {
    _, sourceFrameRefCon, status, _, imageBuffer, presentationTimeStamp, _ in
    guard let sourceFrameRefCon else { return }
    let promise = Unmanaged<H264DecodePromise>.fromOpaque(sourceFrameRefCon).takeUnretainedValue()
    guard status == noErr else {
        promise.resume(with: .failure(H264VideoToolboxError.decodeFailed(status)))
        return
    }
    guard let imageBuffer else {
        promise.resume(with: .failure(H264VideoToolboxError.decodedFrameMissing))
        return
    }
    do {
        guard CVPixelBufferGetPixelFormatType(imageBuffer) == kCVPixelFormatType_32BGRA else {
            throw H264VideoToolboxError.unsupportedPixelFormat
        }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(imageBuffer) else {
            throw H264VideoToolboxError.decodedFrameMissing
        }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let stride = CVPixelBufferGetBytesPerRow(imageBuffer)
        let seconds = CMTimeGetSeconds(presentationTimeStamp)
        let nanoseconds = seconds.isFinite && seconds > 0
            ? UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
            : 0
        promise.resume(with: .success(try OwnedVideoFrame(
            width: width,
            height: height,
            bytesPerRow: stride,
            presentationTimeNanoseconds: nanoseconds,
            bytes: Data(bytes: base, count: stride * height)
        )))
    } catch {
        promise.resume(with: .failure(error))
    }
}
