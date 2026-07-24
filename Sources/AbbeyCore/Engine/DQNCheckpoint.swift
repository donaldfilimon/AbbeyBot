import Foundation

/// On-disk DQN weights (Phase 1). Experience replay stays in-memory; durable journal is Phase 2.
public struct DQNCheckpointBlob: Codable, Sendable, Equatable {
    public var topology: [Int]
    public var gamma: Float
    public var epsilon: Float
    public var stepCount: Int
    public var seed: UInt64?
    /// `weights[layer][neuron][lane]` — 8 lanes per neuron (SIMD8 packing).
    public var onlineWeights: [[[Float]]]
    public var onlineBiases: [[Float]]
    public var targetWeights: [[[Float]]]
    public var targetBiases: [[Float]]

    public init(
        topology: [Int],
        gamma: Float,
        epsilon: Float,
        stepCount: Int,
        seed: UInt64? = nil,
        onlineWeights: [[[Float]]],
        onlineBiases: [[Float]],
        targetWeights: [[[Float]]],
        targetBiases: [[Float]]
    ) {
        self.topology = topology
        self.gamma = gamma
        self.epsilon = epsilon
        self.stepCount = stepCount
        self.seed = seed
        self.onlineWeights = onlineWeights
        self.onlineBiases = onlineBiases
        self.targetWeights = targetWeights
        self.targetBiases = targetBiases
    }
}

public enum DQNCheckpointError: Error, LocalizedError, Sendable {
    case topologyMismatch(expected: [Int], found: [Int])
    case corrupt(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .topologyMismatch(let expected, let found):
            return "DQN checkpoint topology \(found) does not match \(expected)"
        case .corrupt(let detail):
            return "DQN checkpoint corrupt: \(detail)"
        case .io(let detail):
            return "DQN checkpoint I/O: \(detail)"
        }
    }
}

/// Default path `~/.abbey/dqn-checkpoint.json` (desktop, server, CLI).
public enum DQNCheckpointStore: Sendable {
    public static func defaultURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".abbey", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dqn-checkpoint.json", isDirectory: false)
    }

    /// Copies `url` → `url.bak` when present, then writes `data` atomically.
    public static func writeReplacing(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            if fm.fileExists(atPath: bak.path) {
                try fm.removeItem(at: bak)
            }
            try fm.copyItem(at: url, to: bak)
        }
        let tmp = url.appendingPathExtension("tmp")
        if fm.fileExists(atPath: tmp.path) {
            try fm.removeItem(at: tmp)
        }
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
    }
}

extension NeuralNetwork {
    func encodeWeights() -> [[[Float]]] {
        weights.map { layer in
            layer.map { simd in
                (0..<8).map { simd[$0] }
            }
        }
    }

    static func decodeWeights(_ raw: [[[Float]]], topology: [Int]) throws -> [[SIMD8<Float>]] {
        guard raw.count == max(topology.count - 1, 0) else {
            throw DQNCheckpointError.corrupt("weight layer count \(raw.count)")
        }
        var out: [[SIMD8<Float>]] = []
        for (layerIndex, layer) in raw.enumerated() {
            let expected = topology[layerIndex + 1]
            guard layer.count == expected else {
                throw DQNCheckpointError.corrupt("layer \(layerIndex) neuron count \(layer.count)")
            }
            var neurons: [SIMD8<Float>] = []
            for neuron in layer {
                var lanes = Array(neuron.prefix(8))
                if lanes.count < 8 {
                    lanes.append(contentsOf: repeatElement(Float(0), count: 8 - lanes.count))
                }
                neurons.append(SIMD8<Float>(lanes))
            }
            out.append(neurons)
        }
        return out
    }

    mutating func applyCheckpoint(weights rawWeights: [[[Float]]], biases: [[Float]], topology: [Int]) throws {
        guard self.topology == topology else {
            throw DQNCheckpointError.topologyMismatch(expected: self.topology, found: topology)
        }
        self.weights = try Self.decodeWeights(rawWeights, topology: topology)
        guard biases.count == self.weights.count else {
            throw DQNCheckpointError.corrupt("bias layer count")
        }
        for i in 0..<biases.count {
            guard biases[i].count == self.weights[i].count else {
                throw DQNCheckpointError.corrupt("bias neuron count at layer \(i)")
            }
        }
        self.biases = biases
    }
}
