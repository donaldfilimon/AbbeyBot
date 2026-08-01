import COpus

private final class OpusEncoderHandle {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { opus_encoder_destroy(raw) }
}

private final class OpusDecoderHandle {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { opus_decoder_destroy(raw) }
}

/// A fixed Discord audio format codec: 48 kHz, stereo, exactly 20 ms per call.
public actor Opus20msCodec {
    public static let sampleRate: Int32 = 48_000
    public static let channels: Int32 = 2
    public static let samplesPerChannel = 960
    public static let interleavedSampleCount = samplesPerChannel * Int(channels)
    public static let maximumPacketBytes = 1_275

    private let encoder: OpusEncoderHandle
    private let decoder: OpusDecoderHandle

    public init() throws {
        var encoderError: Int32 = OPUS_OK
        guard let encoder = opus_encoder_create(
            Self.sampleRate,
            Self.channels,
            OPUS_APPLICATION_AUDIO,
            &encoderError
        ), encoderError == OPUS_OK else {
            throw NativeMediaError.codecFailure(operation: "encoderCreate", code: encoderError)
        }

        var decoderError: Int32 = OPUS_OK
        guard let decoder = opus_decoder_create(Self.sampleRate, Self.channels, &decoderError),
              decoderError == OPUS_OK else {
            opus_encoder_destroy(encoder)
            throw NativeMediaError.codecFailure(operation: "decoderCreate", code: decoderError)
        }
        self.encoder = OpusEncoderHandle(encoder)
        self.decoder = OpusDecoderHandle(decoder)
    }

    public func encode(_ pcm: [Int16], maximumBytes: Int = maximumPacketBytes) throws -> [UInt8] {
        guard pcm.count == Self.interleavedSampleCount else {
            throw NativeMediaError.invalidFrameLength(
                expected: Self.interleavedSampleCount,
                actual: pcm.count
            )
        }
        guard (1...Self.maximumPacketBytes).contains(maximumBytes) else {
            throw NativeMediaError.invalidPacketLength(actual: maximumBytes)
        }
        var packet = [UInt8](repeating: 0, count: maximumBytes)
        let encodedCount = pcm.withUnsafeBufferPointer { pcmBuffer in
            packet.withUnsafeMutableBufferPointer { packetBuffer in
                opus_encode(
                    encoder.raw,
                    pcmBuffer.baseAddress!,
                    Int32(Self.samplesPerChannel),
                    packetBuffer.baseAddress!,
                    Int32(maximumBytes)
                )
            }
        }
        guard encodedCount >= 0 else {
            throw NativeMediaError.codecFailure(operation: "encode", code: encodedCount)
        }
        packet.removeSubrange(Int(encodedCount)..<packet.count)
        return packet
    }

    public func decode(_ packet: [UInt8], useFEC: Bool = false) throws -> [Int16] {
        guard !packet.isEmpty, packet.count <= Self.maximumPacketBytes else {
            throw NativeMediaError.invalidPacketLength(actual: packet.count)
        }
        return try decode(packetPointer: packet, useFEC: useFEC)
    }

    public func decodePacketLoss() throws -> [Int16] {
        try decode(packetPointer: [], useFEC: false, packetLoss: true)
    }

    private func decode(
        packetPointer packet: [UInt8],
        useFEC: Bool,
        packetLoss: Bool = false
    ) throws -> [Int16] {
        var pcm = [Int16](repeating: 0, count: Self.interleavedSampleCount)
        let decodedSamples = packet.withUnsafeBufferPointer { packetBuffer in
            pcm.withUnsafeMutableBufferPointer { pcmBuffer in
                opus_decode(
                    decoder.raw,
                    packetLoss ? nil : packetBuffer.baseAddress,
                    packetLoss ? 0 : Int32(packet.count),
                    pcmBuffer.baseAddress!,
                    Int32(Self.samplesPerChannel),
                    useFEC ? 1 : 0
                )
            }
        }
        guard decodedSamples >= 0 else {
            throw NativeMediaError.codecFailure(operation: "decode", code: decodedSamples)
        }
        pcm.removeSubrange(Int(decodedSamples) * Int(Self.channels)..<pcm.count)
        return pcm
    }
}
