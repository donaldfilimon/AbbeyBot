import Foundation

/// Feed-forward network, dense per-neuron weight vectors sized to each layer's actual
/// fan-in. This is Donald's own design (see references/brain.md in the skill) — no
/// external ML library.
///
/// Corrected from the reference draft in three ways, all purely mechanical (not a
/// design change, so not flagged as an open decision):
///   1. `forward` is non-mutating. It reads `weights`/`biases` but never writes them,
///      so marking it `mutating` was incorrect and caused spurious `await` call sites
///      when `NeuralNetwork` is a stored property of an actor (DQNAgent) — a plain
///      synchronous struct method call needs no `await` even from within an actor.
///   2. Weight vectors were originally packed into a fixed-width `SIMD8<Float>` per
///      neuron regardless of that layer's real fan-in, truncating/padding to 8 lanes.
///      For this network's actual topology (`[8, 32, 16, 3]`), layers 1 and 2 have
///      fan-in 32 and 16 — every `dot()` silently discarded most of their input, on
///      every forward pass, not just at the external input boundary. Weight vectors are
///      now plain `[Float]` sized to the declared fan-in (`topology[layerIndex]`), so
///      every layer actually consumes what it's fed.
///   3. `train()`'s backward pass propagated error to the previous layer by summing raw
///      weight *values* — never multiplying by that neuron's delta, and never applying
///      the ReLU derivative anywhere (including the output layer's own gradient). Hidden
///      layers therefore never received a gradient connected to the loss, and the output
///      layer's own gradient was wrong whenever a neuron had been clamped to 0. Backprop
///      now computes `delta[j] = (Σᵢ weight[i][j] · delta[i]) · relu'(z[j])` at every
///      layer, using pre-update weights (propagation ran on already-updated weights
///      before this fix).
public struct NeuralNetwork: Sendable {
    public var weights: [[[Float]]]          // weights[layer][neuron][lane], lane count == that layer's fan-in
    public var biases: [[Float]]             // biases[layer][neuron]
    public let topology: [Int]               // e.g. [128, 64, 32, 3]

    public init(topology: [Int], seed: UInt64 = 0) {
        self.topology = topology
        var generator = SplitMix64(seed: seed)
        var w: [[[Float]]] = []
        var b: [[Float]] = []
        for layerIndex in 1..<topology.count {
            let neuronCount = topology[layerIndex]
            let fanIn = topology[layerIndex - 1]
            var layerWeights: [[Float]] = []
            var layerBiases: [Float] = []
            for _ in 0..<neuronCount {
                let scalars = (0..<fanIn).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
                layerWeights.append(scalars)
                layerBiases.append(0)
            }
            w.append(layerWeights)
            b.append(layerBiases)
        }
        self.weights = w
        self.biases = b
    }

    /// Runs one forward pass. Each layer's neurons dot-product against its full declared
    /// fan-in — no truncation. The external input (e.g. SentimentAnalyzer's 18-dimensional
    /// state) must still be projected down to `topology[0]` before calling `forward`. See
    /// `SentimentAnalyzer.projectToNetworkInput`.
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
        var preActivations: [[Float]] = []
        var current = input
        for layerIndex in 0..<weights.count {
            let layerWeights = weights[layerIndex]
            let layerBiases = biases[layerIndex]
            let z = zip(layerWeights, layerBiases).map { weight, bias in dot(weight, current) + bias }
            preActivations.append(z)
            current = z.map(relu)
            activations.append(current)
        }

        // Output layer error as MSE on logits (DQN Bellman targets). Softmax is reserved
        // for `forward(_:)` classification consumers — do not apply it here.
        let outputError = zip(activations.last ?? [], target).map { $0 - $1 }
        var delta = zip(outputError, preActivations[weights.count - 1]).map { $0 * reluDerivative($1) }

        for layerIndex in stride(from: weights.count - 1, through: 0, by: -1) {
            let inputToLayer = activations[layerIndex]
            var propagated = [Float](repeating: 0, count: inputToLayer.count)
            for neuronIndex in 0..<weights[layerIndex].count {
                let gradient = clip(delta[neuronIndex], to: 1.0)
                biases[layerIndex][neuronIndex] -= learningRate * gradient
                let weightVector = weights[layerIndex][neuronIndex]
                if layerIndex > 0 {
                    for previousNeuron in 0..<inputToLayer.count {
                        propagated[previousNeuron] += weightVector[previousNeuron] * gradient
                    }
                }
                var updated = weightVector
                for lane in 0..<inputToLayer.count {
                    updated[lane] -= learningRate * gradient * inputToLayer[lane]
                }
                weights[layerIndex][neuronIndex] = updated
            }
            // Propagate error to the previous layer (skipped for the input layer).
            if layerIndex > 0 {
                let previousPreActivation = preActivations[layerIndex - 1]
                delta = zip(propagated, previousPreActivation).map { $0 * reluDerivative($1) }
            }
        }
    }

    private func relu(_ x: Float) -> Float { max(0, x) }

    private func reluDerivative(_ preActivation: Float) -> Float { preActivation > 0 ? 1 : 0 }

    private func clip(_ x: Float, to bound: Float) -> Float {
        min(max(x, -bound), bound)
    }

    /// Accelerated via `NeuralMath` (Accelerate/vDSP on Apple platforms).
    private func dot(_ weight: [Float], _ input: [Float]) -> Float {
        NeuralMath.dot(weight, input)
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
