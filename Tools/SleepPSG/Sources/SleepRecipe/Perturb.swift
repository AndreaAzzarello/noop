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

    /// One hole of `length` seconds placed uniformly inside `[from, to)`. A span shorter than `length` yields a
    /// hole covering the whole span.
    public static func singleHole(from: Int, to: Int, length: Int, seed: UInt64) -> (from: Int, to: Int) {
        var rng = SplitMix64(seed: seed)
        let room = max(0, to - from - length)
        let start = from + (room > 0 ? rng.int(0, room) : 0)
        return (start, min(to, start + length))
    }

    /// Non-overlapping holes of `burstSeconds` each that together cover about `fraction` of `[from, to)`: the
    /// span is cut into whole bursts and a random subset of them is removed. What a link that drops packets in
    /// runs would leave, as opposed to the independent per-sample loss of `dropHeartRate`.
    public static func burstHoles(from: Int, to: Int, fraction: Double, burstSeconds: Int,
                                  seed: UInt64) -> [(from: Int, to: Int)] {
        let slots = max(0, (to - from) / max(1, burstSeconds))
        let k = min(slots, Int((fraction * Double(slots)).rounded()))
        guard k > 0 else { return [] }
        var rng = SplitMix64(seed: seed)
        var order = Array(0..<slots)
        for i in 0..<k { order.swapAt(i, rng.int(i, slots - 1)) }
        return order.prefix(k).sorted().map { (from + $0 * burstSeconds, from + ($0 + 1) * burstSeconds) }
    }

    /// Remove every gravity sample inside any of `holes`.
    public static func gravityHoles(_ grav: [GravitySample], _ holes: [(from: Int, to: Int)]) -> [GravitySample] {
        grav.filter { g in !holes.contains { g.ts >= $0.from && g.ts < $0.to } }
    }

    /// Remove every heart-rate sample inside any of `holes`.
    public static func heartRateHoles(_ hr: [HRSample], _ holes: [(from: Int, to: Int)]) -> [HRSample] {
        hr.filter { h in !holes.contains { h.ts >= $0.from && h.ts < $0.to } }
    }

    /// FNV-1a over UTF-8, to derive a per-subject seed from an id without Swift's randomised `hashValue`.
    public static func seed(mixing base: UInt64, with text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return base ^ h
    }
}
