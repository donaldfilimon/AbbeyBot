import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Vector math for the feed-forward net and WDBX cosine search.
/// Prefer **Accelerate/vDSP** (Apple Silicon AMX/NEON acceleration) when available;
/// fall back to pure Swift on other platforms.
public enum NeuralMath: Sendable {
    /// Dot product. Uses `vDSP_dotpr` when Accelerate is linked.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        #if canImport(Accelerate)
        var result: Float = 0
        a.withUnsafeBufferPointer { ab in
            b.withUnsafeBufferPointer { bb in
                guard let ap = ab.baseAddress, let bp = bb.baseAddress else { return }
                vDSP_dotpr(ap, 1, bp, 1, &result, vDSP_Length(n))
            }
        }
        return result
        #else
        var s: Float = 0
        for i in 0..<n { s += a[i] * b[i] }
        return s
        #endif
    }

    /// `out[i] = a[i] + b` (scalar add) — Accelerate path when available.
    public static func addScalar(_ a: [Float], _ b: Float) -> [Float] {
        #if canImport(Accelerate)
        var out = [Float](repeating: 0, count: a.count)
        var bb = b
        a.withUnsafeBufferPointer { ab in
            out.withUnsafeMutableBufferPointer { ob in
                guard let ap = ab.baseAddress, let op = ob.baseAddress else { return }
                vDSP_vsadd(ap, 1, &bb, op, 1, vDSP_Length(a.count))
            }
        }
        return out
        #else
        return a.map { $0 + b }
        #endif
    }

    public static var accelerationBackend: String {
        #if canImport(Accelerate)
        return "Accelerate/vDSP (AMX/NEON on Apple Silicon)"
        #else
        return "pure-Swift"
        #endif
    }
}
