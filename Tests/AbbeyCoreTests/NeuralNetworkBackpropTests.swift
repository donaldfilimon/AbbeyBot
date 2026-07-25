import Testing
@testable import AbbeyCore

/// `NeuralNetwork.train()`'s backward pass never multiplied the propagated error by the
/// per-neuron weight *and* delta together (it summed raw weight values), and never applied
/// the ReLU derivative anywhere (output layer included) — so hidden layers received no
/// gradient connected to the loss. Separately, `weights`/`dot` were fixed at 8 SIMD lanes
/// regardless of a layer's actual fan-in, so any layer wider than 8 (this network's real
/// topology is `[8, 32, 16, 3]`) silently ignored most of its input on every forward pass,
/// not just the external boundary. These two tests isolate each defect.
@Suite("NeuralNetwork backprop + fan-in correctness")
struct NeuralNetworkBackpropTests {
    /// Topology `[16, 4]` has a single layer whose fan-in (16) exceeds the old fixed 8
    /// SIMD lanes. Two inputs that agree on the first 8 dimensions and disagree only on
    /// dimensions 8..<16 must produce different outputs if the layer actually consumes its
    /// full declared fan-in.
    @Test func forwardConsumesFullLayerFanInBeyondEightLanes() {
        let network = NeuralNetwork(topology: [16, 4], seed: 11)
        let base: [Float] = [0.1, -0.2, 0.3, 0.4, -0.5, 0.6, 0.7, -0.8, 0, 0, 0, 0, 0, 0, 0, 0]
        var varied = base
        for i in 8..<16 {
            varied[i] = Float(i) * 0.37 - 1.5
        }

        let outputBase = network.forward(base)
        let outputVaried = network.forward(varied)

        #expect(outputBase != outputVaried)
    }

    /// Gradient check: perturbing a single hidden-layer weight by ±eps and re-evaluating
    /// loss gives the true gradient direction via finite differences, independent of
    /// `train()`'s own (possibly buggy) math. `train()`'s actual weight delta for that
    /// same weight must match `learningRate * numericalGradient` within tolerance.
    @Test func trainMovesHiddenLayerWeightByTheNumericalGradient() {
        let topology = [3, 4, 2]
        let seed: UInt64 = 7
        let input: [Float] = [0.5, -0.3, 0.8]
        let target: [Float] = [0.2, 0.9]
        let learningRate: Float = 0.01
        let eps: Float = 0.01

        func loss(_ network: NeuralNetwork) -> Float {
            let output = network.forwardLogits(input)
            return 0.5 * zip(output, target).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        }

        var plus = NeuralNetwork(topology: topology, seed: seed)
        plus.weights[0][0][0] += eps
        var minus = NeuralNetwork(topology: topology, seed: seed)
        minus.weights[0][0][0] -= eps
        let numericalGradient = (loss(plus) - loss(minus)) / (2 * eps)

        var trained = NeuralNetwork(topology: topology, seed: seed)
        let weightBefore = trained.weights[0][0][0]
        trained.train(input: input, target: target, learningRate: learningRate)
        let weightAfter = trained.weights[0][0][0]
        let actualDelta = weightBefore - weightAfter

        let expectedDelta = learningRate * numericalGradient
        #expect(abs(actualDelta - expectedDelta) < 0.002)
    }
}
