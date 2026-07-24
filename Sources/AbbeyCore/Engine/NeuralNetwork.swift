import Foundation

/// Feed-forward network, SIMD8-accelerated per-neuron dot products. This is Donald's
/// own design (see references/brain.md in the skill) — no external ML library.
///
/// Corrected from the reference draft in two ways, both purely mechanical (not a
/// design change, so not flagged as an open decision):
///   1. `forward` is non-mutating. It reads `weights`/`biases` but never writes them,
///      so marking it `mutating` was incorrect and caused spurious `await` call sites
///      when `NeuralNetwork` is a stored property of an actor (DQNAgent) — a plain
///      synchronous struct method call needs no `await` even from within an actor.
///   2. The SIMD8 packing pads/truncates to exactly 8 scalars *before* constructing the
///      SIMD8 value, using a concrete `[Float]` (not a slice) so the element count the
///      `SIMD8(_:)` sequence initializer receives is unambiguous.
public struct NeuralNetwork: Sendable {
    public var weights: [[SIMD8<Float>]]     // weights[layer][neuron], padded/truncated to 8 lanes
    public var biases: [[Float]]             // biases[layer][neuron]
    public let topology: [Int]               // e.g. [128, 64, 32, 3]

    public init(topology: [Int], seed: UInt64 = 0) {
        self.topology = topology
        var generator = SplitMix64(seed: seed)
        var w: [[SIMD8<Float>]] = []
        var b: [[Float]] = []
        for layerIndex in 1..<topology.count {
            let neuronCount = topology[layerIndex]
            var layerWeights: [SIMD8<Float>] = []
            var layerBiases: [Float] = []
            for _ in 0..<neuronCount {
                let scalars = (0..<8).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
                layerWeights.append(SIMD8<Float>(scalars))
                layerBiases.append(0)
            }
            w.append(layerWeights)
            b.append(layerBiases)
        }
        self.weights = w
        self.biases = b
    }

    /// Runs one forward pass. Each layer collapses its input vector to 8 packed lanes
    /// (dot-producted against each neuron's SIMD8 weight vector), so this network only
    /// ever "sees" the first 8 dimensions of whatever it's fed — that's a real
    /// architectural constraint of this design, not a bug: inputs wider than 8 (e.g.
    /// SentimentAnalyzer's 18-dimensional state) must be projected down before calling
    /// `forward`. See `SentimentAnalyzer.projectToNetworkInput`.
    public func forward(_ input: [Float]) -> [Float] {
        var activation = input
        for layerIndex in 0..<weights.count {
            let layerWeights = weights[layerIndex]
            let layerBiases = biases[layerIndex]
            activation = zip(layerWeights, layerBiases).map { weight, bias in
                relu(dot(weight, activation) + bias)
            }
        }
        return softmax(activation)
    }

    /// Same forward pass as `forward(_:)` but returns the raw final-layer activations
    /// *without* the softmax. Use this for Q-value estimation (DQNAgent) — softmaxing
    /// Q-values is the "open decision" flagged in the skill (references/brain.md /
    /// /areas/discord-abbey-skill.md): softmax compresses the relative magnitude
    /// between actions, which quietly prevents the Bellman-target regression from
    /// converging, because `argmax(softmax(x)) == argmax(x)` for action *selection*
    /// but the *values* driving `train(target:)` are no longer real Q-values once
    /// softmax has been applied to them.
    ///
    /// `forward(_:)` keeps its softmax and stays the right call for classification-style
    /// consumers (persona/intent scoring). This method is the fix for the DQN call site
    /// specifically — added here rather than changing `forward(_:)` itself, so nothing
    /// upstream silently changes behavior. Flagging this choice to Donald rather than
    /// treating it as settled.
    public func forwardLogits(_ input: [Float]) -> [Float] {
        var activation = input
        for layerIndex in 0..<weights.count {
            let layerWeights = weights[layerIndex]
            let layerBiases = biases[layerIndex]
            activation = zip(layerWeights, layerBiases).map { weight, bias in
                relu(dot(weight, activation) + bias)
            }
        }
        return activation
    }

    /// Backprop with gradient clipping (±1.0). Mutates in place, so callers hold a
    /// `var NeuralNetwork` (DQNAgent stores `online`/`target` as `var` properties).
    public mutating func train(input: [Float], target: [Float], learningRate: Float = 0.001) {
        var activations: [[Float]] = [input]
        var current = input
        for layerIndex in 0..<weights.count {
            let layerWeights = weights[layerIndex]
            let layerBiases = biases[layerIndex]
            current = zip(layerWeights, layerBiases).map { weight, bias in
                relu(dot(weight, current) + bias)
            }
            activations.append(current)
        }

        // Output layer error as MSE on logits (DQN Bellman targets). Softmax is reserved
        // for `forward(_:)` classification consumers — do not apply it here.
        var delta = zip(activations.last ?? [], target).map { $0 - $1 }

        for layerIndex in stride(from: weights.count - 1, through: 0, by: -1) {
            let inputToLayer = activations[layerIndex]
            for neuronIndex in 0..<weights[layerIndex].count {
                let gradient = clip(delta[neuronIndex], to: 1.0)
                biases[layerIndex][neuronIndex] -= learningRate * gradient
                var updated = weights[layerIndex][neuronIndex]
                for lane in 0..<min(8, inputToLayer.count) {
                    updated[lane] -= learningRate * gradient * inputToLayer[lane]
                }
                weights[layerIndex][neuronIndex] = updated
            }
            // Propagate error to the previous layer (skipped for the input layer).
            if layerIndex > 0 {
                delta = (0..<inputToLayer.count).map { previousNeuron in
                    weights[layerIndex].reduce(Float(0)) { partial, weight in
                        let lane = previousNeuron < 8 ? weight[previousNeuron] : 0
                        return partial + lane
                    }
                }
            }
        }
    }

    private func relu(_ x: Float) -> Float { max(0, x) }

    private func clip(_ x: Float, to bound: Float) -> Float {
        min(max(x, -bound), bound)
    }

    private func dot(_ weight: SIMD8<Float>, _ input: [Float]) -> Float {
        var padded = Array(input.prefix(8))
        if padded.count < 8 {
            padded.append(contentsOf: repeatElement(0, count: 8 - padded.count))
        }
        let vector = SIMD8<Float>(padded)
        return (weight * vector).sum()
    }

    private func softmax(_ logits: [Float]) -> [Float] {
        guard let maxLogit = logits.max() else { return [] }
        let exponentials = logits.map { expf($0 - maxLogit) }
        let sum = exponentials.reduce(0, +)
        guard sum > 0 else { return logits.map { _ in 1.0 / Float(max(logits.count, 1)) } }
        return exponentials.map { $0 / sum }
    }
}

/// Deterministic, seedable PRNG so network initialization is reproducible in tests
/// without pulling in a third-party dependency (stdlib-first preference).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
