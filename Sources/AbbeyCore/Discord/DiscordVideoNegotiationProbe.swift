import Foundation
import CoreFoundation

public struct DiscordVideoNegotiationObservation: Codable, Equatable, Sendable {
    public var opcode: Int
    public var fieldPath: String
    public var codecLabel: String
    public var payloadType: UInt8
    public var daveProtocolVersion: Int?
    public var elapsedMilliseconds: UInt64
}

/// Metadata-only canary probe. It never retains the source JSON, tokens,
/// identities, packet bodies, frames, or arbitrary remote strings.
public actor DiscordVideoNegotiationProbe {
    private let startedAt: ContinuousClock.Instant
    private let maximumObservations: Int
    private var values: [DiscordVideoNegotiationObservation] = []

    public init(maximumObservations: Int = 128) {
        startedAt = .now
        self.maximumObservations = min(max(maximumObservations, 1), 512)
    }

    public func observations() -> [DiscordVideoNegotiationObservation] { values }

    public func observe(_ data: Data, daveProtocolVersion: Int?) {
        guard data.count <= VoiceGatewayV8Decoder.maximumPayloadBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let opcode = root["op"] as? Int,
              (0...255).contains(opcode)
        else { return }
        var remainingNodes = 2_048
        scan(
            root,
            path: [],
            opcode: opcode,
            daveProtocolVersion: daveProtocolVersion,
            depth: 0,
            remainingNodes: &remainingNodes
        )
    }

    private func scan(
        _ object: Any,
        path: [String],
        opcode: Int,
        daveProtocolVersion: Int?,
        depth: Int,
        remainingNodes: inout Int
    ) {
        guard depth <= 16, remainingNodes > 0 else { return }
        remainingNodes -= 1
        if let dictionary = object as? [String: Any] {
            let codecKeys = ["codec", "codec_name", "name"]
            let payloadKeys = ["payload_type", "payloadType", "pt"]
            let codec = codecKeys.compactMap { dictionary[$0] as? String }
                .compactMap(Self.canonicalCodec).first
            let payload = payloadKeys.compactMap { Self.uint8(dictionary[$0]) }.first
            if let codec, let payload {
                append(.init(
                    opcode: opcode,
                    fieldPath: Self.safeFieldPath(path),
                    codecLabel: codec,
                    payloadType: payload,
                    daveProtocolVersion: daveProtocolVersion,
                    elapsedMilliseconds: Self.milliseconds(startedAt.duration(to: .now))
                ))
            }
            for key in dictionary.keys.sorted() {
                guard remainingNodes > 0 else { break }
                // Remote JSON keys are untrusted and may themselves contain an
                // identifier. Only protocol vocabulary enters the receipt;
                // unknown containers remain searchable but are labeled
                // generically instead of copied.
                let component = Self.safePathComponents.contains(key) ? key : "other"
                scan(
                    dictionary[key] as Any,
                    path: Array((path + [component]).suffix(12)),
                    opcode: opcode,
                    daveProtocolVersion: daveProtocolVersion,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes
                )
            }
        } else if let array = object as? [Any] {
            for item in array.prefix(64) {
                guard remainingNodes > 0 else { break }
                scan(
                    item,
                    path: path + ["[]"],
                    opcode: opcode,
                    daveProtocolVersion: daveProtocolVersion,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes
                )
            }
        }
    }

    private func append(_ observation: DiscordVideoNegotiationObservation) {
        guard !values.contains(where: {
            $0.opcode == observation.opcode
                && $0.fieldPath == observation.fieldPath
                && $0.codecLabel == observation.codecLabel
                && $0.payloadType == observation.payloadType
                && $0.daveProtocolVersion == observation.daveProtocolVersion
        }) else { return }
        values.append(observation)
        if values.count > maximumObservations {
            values.removeFirst(values.count - maximumObservations)
        }
    }

    private static let safePathComponents: Set<String> = [
        "d", "codecs", "audio_codec", "video_codec", "codec", "codec_name",
        "name", "payload_type", "payloadType", "pt", "streams", "type", "media",
    ]

    private static func safeFieldPath(_ components: [String]) -> String {
        guard !components.isEmpty else { return "root" }
        let path = components.reduce(into: "") { result, component in
            if component == "[]" {
                result += component
            } else {
                if !result.isEmpty { result += "." }
                result += component
            }
        }
        return String(path.prefix(160))
    }

    private static func milliseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let fractional = UInt64(max(0, components.attoseconds)) / 1_000_000_000_000_000
        return seconds.multipliedReportingOverflow(by: 1_000).partialValue &+ fractional
    }

    private static func canonicalCodec(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "H264", "H.264": "H264"
        case "H265", "H.265", "HEVC": "H265"
        case "VP8": "VP8"
        case "VP9": "VP9"
        case "AV1": "AV1"
        default: nil
        }
    }

    private static func uint8(_ value: Any?) -> UInt8? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value.rounded(.towardZero) == value else { return nil }
            return UInt8(exactly: value)
        }
        if let string = value as? String, let integer = Int(string) { return UInt8(exactly: integer) }
        return nil
    }
}
