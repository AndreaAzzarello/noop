import Foundation
import WhoopProtocol

// Perturb — deterministic damage to a night's input streams, for asking "how much does the hypnogram move when
// the data gets worse". Seeded, so the same damage lands on the same samples in every run and on every variant
// being compared; the point is the DIFFERENCE between recipes under identical damage.

/// SplitMix64 — a tiny deterministic PRNG, so generated nights and the damage done to them are identical on
/// every machine and every run. Not for anything that needs randomness quality.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func double(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo..<hi, using: &self) }
    public mutating func int(_ lo: Int, _ hi: Int) -> Int { Int.random(in: lo...hi, using: &self) }
    public mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double.random(in: 0..<1, using: &self) }
}

public enum Perturb {
    /// Remove each heart-rate sample independently with probability `fraction`.
    public static func dropHeartRate(_ hr: [HRSample], fraction: Double, seed: UInt64) -> [HRSample] {
        var rng = SplitMix64(seed: seed)
        return hr.filter { _ in rng.unit() >= fraction }
    }

    /// Remove each R-R beat independently with probability `fraction`.
    public static func dropBeats(_ rr: [RRInterval], fraction: Double, seed: UInt64) -> [RRInterval] {
        var rng = SplitMix64(seed: seed)
        return rr.filter { _ in rng.unit() >= fraction }
    }

    /// Remove every gravity sample with `from <= ts < to`: a contiguous hole, as a strap that stopped
    /// banking motion would leave.
    public static func gravityHole(_ grav: [GravitySample], from: Int, to: Int) -> [GravitySample] {
        grav.filter { $0.ts < from || $0.ts >= to }
    }

    /// The same, for heart rate (a contiguous hole).
    public static func heartRateHole(_ hr: [HRSample], from: Int, to: Int) -> [HRSample] {
        hr.filter { $0.ts < from || $0.ts >= to }
    }
}
