import Foundation

public enum AudioPCMSampleStorage: Equatable, Sendable {
    case float32([Float])
    case int16([Int16])
}

public enum AudioPCMFrameError: Error, Equatable, Sendable {
    case unsupportedSampleRate(Double)
    case unsupportedChannelCount(Int)
    case incorrectSampleCount(actual: Int, expected: Int)
}

public struct AudioPCMFrame: Equatable, Sendable {
    public static let sampleRate = 48_000.0
    public static let channelCount = 2
    public static let durationSeconds = 0.020
    public static let framesPerChannel = 960
    public static let interleavedSampleCount = framesPerChannel * channelCount

    public let samples: AudioPCMSampleStorage
    public let frameCount = Self.framesPerChannel

    public init(
        float32 samples: [Float],
        sampleRate: Double = Self.sampleRate,
        channelCount: Int = Self.channelCount
    ) throws {
        try Self.validate(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        self.samples = .float32(samples)
    }

    public init(
        int16 samples: [Int16],
        sampleRate: Double = Self.sampleRate,
        channelCount: Int = Self.channelCount
    ) throws {
        try Self.validate(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        self.samples = .int16(samples)
    }

    public var float32Samples: [Float] {
        switch samples {
        case let .float32(values):
            values
        case let .int16(values):
            values.map { value in
                value < 0 ? Float(value) / 32_768.0 : Float(value) / 32_767.0
            }
        }
    }

    public var int16Samples: [Int16] {
        switch samples {
        case let .int16(values):
            values
        case let .float32(values):
            values.map { value in
                if !value.isFinite { return 0 }
                if value <= -1 { return Int16.min }
                if value >= 1 { return Int16.max }
                return Int16((value * Float(Int16.max)).rounded())
            }
        }
    }

    public func convertedToFloat32() throws -> AudioPCMFrame {
        try AudioPCMFrame(float32: float32Samples)
    }

    public func convertedToInt16() throws -> AudioPCMFrame {
        try AudioPCMFrame(int16: int16Samples)
    }

    private static func validate(
        sampleCount: Int,
        sampleRate: Double,
        channelCount: Int
    ) throws {
        guard sampleRate == Self.sampleRate else {
            throw AudioPCMFrameError.unsupportedSampleRate(sampleRate)
        }
        guard channelCount == Self.channelCount else {
            throw AudioPCMFrameError.unsupportedChannelCount(channelCount)
        }
        guard sampleCount == interleavedSampleCount else {
            throw AudioPCMFrameError.incorrectSampleCount(
                actual: sampleCount,
                expected: interleavedSampleCount
            )
        }
    }
}

/// Accumulates owned, normalized PCM samples into Discord's exact 20 ms packet cadence.
/// The assembler performs no resampling; callers must provide 48 kHz stereo interleaved data.
public struct DiscordAudioFrameAssembler: Sendable {
    private var pending: [Float] = []

    public init() {}

    public var pendingSampleCount: Int { pending.count }

    public mutating func append(
        interleavedFloat32 samples: [Float],
        sampleRate: Double = AudioPCMFrame.sampleRate,
        channelCount: Int = AudioPCMFrame.channelCount
    ) throws -> [AudioPCMFrame] {
        guard sampleRate == AudioPCMFrame.sampleRate else {
            throw AudioPCMFrameError.unsupportedSampleRate(sampleRate)
        }
        guard channelCount == AudioPCMFrame.channelCount else {
            throw AudioPCMFrameError.unsupportedChannelCount(channelCount)
        }

        pending.append(contentsOf: samples)
        var frames: [AudioPCMFrame] = []
        while pending.count >= AudioPCMFrame.interleavedSampleCount {
            let frameSamples = Array(pending.prefix(AudioPCMFrame.interleavedSampleCount))
            pending.removeFirst(AudioPCMFrame.interleavedSampleCount)
            frames.append(try AudioPCMFrame(float32: frameSamples))
        }
        return frames
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}
