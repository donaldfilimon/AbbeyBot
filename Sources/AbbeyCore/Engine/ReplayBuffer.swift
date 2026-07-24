import Foundation

public struct Experience: Sendable {
    public let state: [Float]
    public let action: Int
    public let reward: Float
    public let nextState: [Float]
    public let done: Bool

    public init(state: [Float], action: Int, reward: Float, nextState: [Float], done: Bool) {
        self.state = state
        self.action = action
        self.reward = reward
        self.nextState = nextState
        self.done = done
    }
}

/// Fixed-capacity ring buffer of experiences. Not an actor itself — it's owned
/// exclusively by `DQNAgent`, which is already actor-isolated, so no separate
/// synchronization is needed here.
public struct ReplayBuffer: Sendable {
    private var storage: [Experience] = []
    public let capacity: Int

    public init(capacity: Int = 10_000) {
        self.capacity = capacity
    }

    public var count: Int { storage.count }

    public mutating func add(_ experience: Experience) {
        storage.append(experience)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public func sample(size: Int, using generator: inout some RandomNumberGenerator) -> [Experience] {
        guard !storage.isEmpty else { return [] }
        let count = min(size, storage.count)
        var indices = Array(storage.indices)
        indices.shuffle(using: &generator)
        return indices.prefix(count).map { storage[$0] }
    }
}
