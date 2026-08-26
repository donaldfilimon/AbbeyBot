public enum DiscordVoiceMediaContractError: Error, Equatable, Sendable {
    case invalidQueueCapacity(Int)
    case invalidCredentialTimeout
    case invalidAutoReconnectAttempts(Int)
    case invalidConsentEpoch
}

public enum DiscordVoiceVideoSource: String, Equatable, Sendable {
    case camera
    case screen
}

/// An owned audio frame. Byte storage is held by value so callers may safely
/// transfer a frame across actor boundaries without retaining capture buffers.
public struct DiscordVoiceOwnedAudioFrame: Equatable, Sendable {
    public let generation: UInt64
    public let captureTimestamp: UInt64
    public let sampleCount: UInt32
    public let bytes: [UInt8]

    public init(
        generation: UInt64,
        captureTimestamp: UInt64,
        sampleCount: UInt32,
        bytes: [UInt8]
    ) {
        self.generation = generation
        self.captureTimestamp = captureTimestamp
        self.sampleCount = sampleCount
        self.bytes = Array(bytes)
    }
}

/// An owned camera or screen frame. Pixel storage is deliberately opaque to
/// keep this contract portable across Apple and server builds.
public struct DiscordVoiceOwnedVideoFrame: Equatable, Sendable {
    public let generation: UInt64
    public let captureTimestamp: UInt64
    public let source: DiscordVoiceVideoSource
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init(
        generation: UInt64,
        captureTimestamp: UInt64,
        source: DiscordVoiceVideoSource,
        width: Int,
        height: Int,
        bytes: [UInt8]
    ) {
        self.generation = generation
        self.captureTimestamp = captureTimestamp
        self.source = source
        self.width = width
        self.height = height
        self.bytes = Array(bytes)
    }
}

public enum DiscordVoiceOwnedMediaFrame: Equatable, Sendable {
    case audio(DiscordVoiceOwnedAudioFrame)
    case video(DiscordVoiceOwnedVideoFrame)

    public var generation: UInt64 {
        switch self {
        case .audio(let frame): frame.generation
        case .video(let frame): frame.generation
        }
    }
}

public enum DiscordVoiceQueueAdmission<Element: Sendable>: Sendable {
    case accepted
    case acceptedDroppingOldest(Element)
}

/// A deterministic bounded FIFO. Backpressure drops the oldest frame so a live
/// sender cannot accumulate unbounded latency or memory.
public struct DiscordVoiceBoundedQueue<Element: Sendable>: Sendable {
    public let capacity: Int
    public private(set) var droppedCount: UInt64
    private var elements: [Element]

    public init(capacity: Int) throws {
        guard capacity > 0 else {
            throw DiscordVoiceMediaContractError.invalidQueueCapacity(capacity)
        }
        self.capacity = capacity
        self.droppedCount = 0
        self.elements = []
        self.elements.reserveCapacity(capacity)
    }

    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }

    @discardableResult
    public mutating func enqueue(_ element: Element) -> DiscordVoiceQueueAdmission<Element> {
        if elements.count < capacity {
            elements.append(element)
            return .accepted
        }
        let dropped = elements.removeFirst()
        elements.append(element)
        droppedCount &+= 1
        return .acceptedDroppingOldest(dropped)
    }

    public mutating func dequeue() -> Element? {
        guard !elements.isEmpty else { return nil }
        return elements.removeFirst()
    }

    public mutating func removeAll() {
        elements.removeAll(keepingCapacity: true)
    }
}
