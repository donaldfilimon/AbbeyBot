import Foundation

/// Deep Q-Network agent driving Abbey's self-learning loop: MessageCreate → WDBX/local
/// ingest → reward on reactions → `learn()`.
///
/// Two corrections versus the reference draft in brain.md, both mechanical:
///   1. `online`/`target` are plain (non-async) `NeuralNetwork` values, so calling their
///      methods from within this actor needs no `await` — the reference draft's
///      `await online.forward(state)` was calling `await` on a synchronous method,
///      which only compiled by accident of `forward` also being (incorrectly) `mutating`
///      in a context where the compiler inserted an implicit actor-hop. Making
///      `forward`/`forwardLogits` non-mutating (see NeuralNetwork.swift) removes the
///      ambiguity entirely.
///   2. Q-value estimation uses `forwardLogits`, not `forward` — see the comment on
///      `NeuralNetwork.forwardLogits` for why. This is the flagged-not-silent fix for
///      the "softmax on Q-values" open decision.
public actor DQNAgent {
    private(set) var online: NeuralNetwork
    private(set) var target: NeuralNetwork
    private var buffer: ReplayBuffer
    private var rng: SplitMix64

    public let gamma: Float
    public let epsilon: Float
    private(set) var stepCount = 0

    public init(topology: [Int], gamma: Float = 0.99, epsilon: Float = 0.1, bufferCapacity: Int = 10_000, seed: UInt64 = 42) {
        self.online = NeuralNetwork(topology: topology, seed: seed)
        self.target = online
        self.buffer = ReplayBuffer(capacity: bufferCapacity)
        self.rng = SplitMix64(seed: seed &+ 1)
        self.gamma = gamma
        self.epsilon = epsilon
    }

    /// ε-greedy action selection over raw Q-values.
    public func selectAction(state: [Float]) -> Int {
        guard let actionCount = online.topology.last, actionCount > 0 else { return 0 }
        if Float.random(in: 0...1, using: &rng) < epsilon {
            return Int.random(in: 0..<actionCount, using: &rng)
        }
        let qValues = online.forwardLogits(state)
        guard let best = qValues.enumerated().max(by: { $0.element < $1.element }) else { return 0 }
        return best.offset
    }

    public func remember(_ experience: Experience) {
        buffer.add(experience)
    }

    /// One learning step over a random minibatch. No-op until the buffer has at least
    /// `batchSize` experiences, matching the reference draft's guard.
    public func learn(batchSize: Int = 64) {
        guard buffer.count >= batchSize else { return }
        let batch = buffer.sample(size: batchSize, using: &rng)

        for experience in batch {
            let nextQValues = target.forwardLogits(experience.nextState)
            let bestNextQ = nextQValues.max() ?? 0
            let bootstrapped = experience.done ? experience.reward : experience.reward + gamma * bestNextQ

            var targetVector = online.forwardLogits(experience.state)
            if experience.action < targetVector.count {
                targetVector[experience.action] = bootstrapped
            }
            online.train(input: experience.state, target: targetVector)
        }

        stepCount += 1
        if stepCount % 100 == 0 {
            target = online   // periodic target-network sync
        }
    }
}
