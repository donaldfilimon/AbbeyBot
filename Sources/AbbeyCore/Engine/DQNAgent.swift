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
    private let seed: UInt64
    private let checkpointURL: URL?
    private let experienceJournal: ExperienceJournal?

    public let gamma: Float
    public private(set) var epsilon: Float
    private(set) var stepCount = 0

    public init(
        topology: [Int],
        gamma: Float = 0.99,
        epsilon: Float = 0.1,
        bufferCapacity: Int = 10_000,
        seed: UInt64 = 42,
        checkpointURL: URL? = nil,
        experienceJournalURL: URL? = nil
    ) {
        self.online = NeuralNetwork(topology: topology, seed: seed)
        self.target = online
        self.buffer = ReplayBuffer(capacity: bufferCapacity)
        self.rng = SplitMix64(seed: seed &+ 1)
        self.seed = seed
        self.gamma = gamma
        self.epsilon = epsilon
        self.checkpointURL = checkpointURL
        if let experienceJournalURL {
            self.experienceJournal = ExperienceJournal(url: experienceJournalURL)
        } else {
            self.experienceJournal = nil
        }
    }

    /// Load checkpoint from disk when present. No-op if URL missing or file absent.
    public func loadCheckpointIfPresent() async throws {
        guard let url = checkpointURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try load(from: url)
    }

    /// Replay recent journal lines into the in-memory buffer (append-only file unchanged).
    public func loadExperienceJournalIfPresent(limit: Int = 10_000) throws {
        guard let journal = experienceJournal else { return }
        let experiences = try journal.loadRecent(limit: limit)
        for experience in experiences {
            buffer.add(experience)
        }
    }

    /// Snapshot checkpoint then write (RollbackStore + `*.bak` via writeReplacing).
    public func save(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path),
           (try? RollbackStore.isManaged(url)) == true {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            _ = try? RollbackStore.snapshot(file: url, as: "dqn-checkpoint-\(stamp)")
        }
        let blob = DQNCheckpointBlob(
            topology: online.topology,
            gamma: gamma,
            epsilon: epsilon,
            stepCount: stepCount,
            seed: seed,
            onlineWeights: online.encodeWeights(),
            onlineBiases: online.biases,
            targetWeights: target.encodeWeights(),
            targetBiases: target.biases
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(blob)
        } catch {
            throw DQNCheckpointError.corrupt(error.localizedDescription)
        }
        do {
            try DQNCheckpointStore.writeReplacing(data, to: url)
        } catch let error as DQNCheckpointError {
            throw error
        } catch {
            throw DQNCheckpointError.io(error.localizedDescription)
        }
    }

    public func load(from url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DQNCheckpointError.io(error.localizedDescription)
        }
        let blob: DQNCheckpointBlob
        do {
            blob = try JSONDecoder().decode(DQNCheckpointBlob.self, from: data)
        } catch {
            throw DQNCheckpointError.corrupt(error.localizedDescription)
        }
        guard blob.topology == online.topology else {
            throw DQNCheckpointError.topologyMismatch(expected: online.topology, found: blob.topology)
        }
        try online.applyCheckpoint(weights: blob.onlineWeights, biases: blob.onlineBiases, topology: blob.topology)
        try target.applyCheckpoint(weights: blob.targetWeights, biases: blob.targetBiases, topology: blob.topology)
        stepCount = blob.stepCount
        epsilon = blob.epsilon
    }

    /// Restore weights from `url.bak` when present, then reload into this agent.
    public func restoreCheckpointFromBak() throws {
        guard let url = checkpointURL else {
            throw DQNCheckpointError.io("no checkpoint URL configured")
        }
        try RollbackStore.restoreFromBak(url)
        try load(from: url)
    }

    /// Test helper: force ε for deterministic `selectAction` checks.
    public func setEpsilonForTesting(_ value: Float) {
        epsilon = value
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
        if let journal = experienceJournal {
            try? journal.append(experience)
        }
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
            if let url = checkpointURL {
                try? save(to: url)
            }
        }
    }
}
