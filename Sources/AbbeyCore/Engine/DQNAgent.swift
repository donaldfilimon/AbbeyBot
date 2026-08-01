import Foundation

/// Exactly one durable owner for each DQN experience.
public enum DQNExperiencePersistence: Sendable {
    case journal(ExperienceJournal)
    case memory(WDBXMemoryFacade)

    fileprivate func append(_ experience: Experience) throws {
        switch self {
        case .journal(let journal):
            try journal.append(experience)
        case .memory(let memory):
            try memory.remember(experience)
        }
    }

    fileprivate func loadRecent(limit: Int) throws -> [Experience] {
        switch self {
        case .journal(let journal):
            return try journal.loadRecent(limit: limit)
        case .memory(let memory):
            return try memory.recent(limit: limit)
        }
    }
}

/// Deep Q-Network agent for Abbey's learning loop: ingest → `selectAction` →
/// `remember`/`learn`, with durable checkpoint + experience journal.
///
/// **Claim-honest:** the four-wide action head dispatches answer / clarify / retrieve /
/// refuse. `IngestScorer` currently trains it as a terminal contextual bandit using an
/// immediate, action-conditioned heuristic reward; it does not yet learn from delayed
/// reactions or moderation outcomes. See AGENTS.md Learning & Safety Policy.
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
    /// Default topology: 8-d projected state → hidden → 4 strategy actions
    /// (`StrategyAction`: answer / clarify / retrieve / refuse).
    /// Changing this invalidates old checkpoints (topology mismatch → re-init).
    public static let defaultTopology: [Int] = [8, 64, 32, 4]

    private(set) var online: NeuralNetwork
    private(set) var target: NeuralNetwork
    private var buffer: ReplayBuffer
    private var rng: SplitMix64
    private let seed: UInt64
    private let checkpointURL: URL?
    private let experiencePersistence: DQNExperiencePersistence?

    public let gamma: Float
    public private(set) var epsilon: Float
    private(set) var stepCount = 0
    /// Last selected strategy (for dashboards / craftReply).
    public private(set) var lastStrategy: StrategyAction = .answer
    public private(set) var lastQValues: [Float] = []

    public init(
        topology: [Int] = DQNAgent.defaultTopology,
        gamma: Float = 0.99,
        epsilon: Float = 0.1,
        bufferCapacity: Int = 10_000,
        seed: UInt64 = 42,
        checkpointURL: URL? = nil,
        experienceJournalURL: URL? = nil,
        wdbxFacade: WDBXMemoryFacade? = nil
    ) {
        self.online = NeuralNetwork(topology: topology, seed: seed)
        self.target = online
        self.buffer = ReplayBuffer(capacity: bufferCapacity)
        self.rng = SplitMix64(seed: seed &+ 1)
        self.seed = seed
        self.gamma = gamma
        self.epsilon = epsilon
        self.checkpointURL = checkpointURL
        if let wdbxFacade {
            self.experiencePersistence = .memory(wdbxFacade)
        } else if let experienceJournalURL {
            self.experiencePersistence = .journal(ExperienceJournal(url: experienceJournalURL))
        } else {
            self.experiencePersistence = nil
        }
    }

    /// Preferred constructor: the caller chooses one persistence owner explicitly.
    public init(
        topology: [Int] = DQNAgent.defaultTopology,
        gamma: Float = 0.99,
        epsilon: Float = 0.1,
        bufferCapacity: Int = 10_000,
        seed: UInt64 = 42,
        checkpointURL: URL? = nil,
        experiencePersistence: DQNExperiencePersistence?
    ) {
        self.online = NeuralNetwork(topology: topology, seed: seed)
        self.target = online
        self.buffer = ReplayBuffer(capacity: bufferCapacity)
        self.rng = SplitMix64(seed: seed &+ 1)
        self.seed = seed
        self.gamma = gamma
        self.epsilon = epsilon
        self.checkpointURL = checkpointURL
        self.experiencePersistence = experiencePersistence
    }

    /// Load checkpoint from disk when present. No-op if URL missing or file absent.
    public func loadCheckpointIfPresent() async throws {
        guard let url = checkpointURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try load(from: url)
    }

    /// Replay recent journal lines into the in-memory buffer (append-only file unchanged).
    public func loadExperienceJournalIfPresent(limit: Int = 10_000) throws {
        guard let experiencePersistence else { return }
        let experiences = try experiencePersistence.loadRecent(limit: limit)
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
        guard blob.epsilon.isFinite, (0...1).contains(blob.epsilon), blob.gamma.isFinite, blob.stepCount >= 0 else {
            throw DQNCheckpointError.corrupt("invalid scalar state")
        }

        // Decode and validate into copies. A corrupt target network must not leave the
        // live online network (or scalar state) partially updated.
        var candidateOnline = online
        var candidateTarget = target
        try candidateOnline.applyCheckpoint(weights: blob.onlineWeights, biases: blob.onlineBiases, topology: blob.topology)
        try candidateTarget.applyCheckpoint(weights: blob.targetWeights, biases: blob.targetBiases, topology: blob.topology)

        online = candidateOnline
        target = candidateTarget
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
        let qValues = online.forwardLogits(state)
        lastQValues = qValues
        let action: Int
        if Float.random(in: 0...1, using: &rng) < epsilon {
            action = Int.random(in: 0..<actionCount, using: &rng)
        } else if let best = qValues.enumerated().max(by: { $0.element < $1.element }) {
            action = best.offset
        } else {
            action = 0
        }
        lastStrategy = StrategyAction.from(raw: action)
        return action
    }

    public func remember(_ experience: Experience) {
        buffer.add(experience)
        if let experiencePersistence {
            try? experiencePersistence.append(experience)
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
            epsilon = max(0.05, epsilon * 0.995)
        }
    }

    public func bufferCount() -> Int { buffer.count }

    public func accelerationInfo() -> String {
        NeuralMath.accelerationBackend
    }
}
