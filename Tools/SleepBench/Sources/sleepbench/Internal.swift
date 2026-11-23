import Foundation
import SleepRecipe
import StrandAnalytics
import WhoopProtocol

// Support for sections H-K: pure helpers, no database and no printing, so they run under `swift test` on
// synthetic nights. The sections themselves (printing, reading the database) live in Sections.swift.
//
// Everything in H-K is an INTERNAL-CONSISTENCY or DIFFERENCE measure. None of it is accuracy against real
// sleep, and the tables say so in their own headers.

/// Everything needed to stage one night again, under any recipe or after any damage to its inputs.
struct NightInput {
    var start: Int
    var end: Int
    var grav: [GravitySample]
    var hr: [HRSample]
    var rr: [RRInterval]
    var resp: [RespSample]
}

enum Candidate {
    /// Per-epoch labels of `input` under `cfg`, on the same grid `epochLabels` gives the shipped stagers.
    static func labels(_ i: NightInput, _ cfg: RecipeConfig) -> [String] {
        let segs = V2Recipe.stageSession(start: i.start, end: i.end, grav: i.grav, hr: i.hr, rr: i.rr,
                                         resp: i.resp, cfg: cfg)
        return epochLabels(segs, start: i.start, end: i.end)
    }

    /// Labels and the wall-clock milliseconds the staging took.
    static func timedLabels(_ i: NightInput, _ cfg: RecipeConfig) -> (labels: [String], ms: Double) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let l = labels(i, cfg)
        return (l, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
}

// MARK: - Statistics

enum Sign {
    /// Exact two-sided binomial sign test over `wins` and `losses` (ties are dropped by the caller):
    /// p = min(1, 2 · P(X ≤ min(wins, losses))), X ~ Binomial(wins + losses, 1/2).
    static func p(wins: Int, losses: Int) -> Double {
        let n = wins + losses
        guard n > 0 else { return 1 }
        let k = min(wins, losses)
        var cumulative = 0.0
        for i in 0...k {
            cumulative += exp(lgamma(Double(n + 1)) - lgamma(Double(i + 1)) - lgamma(Double(n - i + 1))
                              - Double(n) * log(2.0))
        }
        return min(1, 2 * cumulative)
    }

    /// Per-night comparison of `b` against `a` where larger is better. A non-finite pair is skipped.
    static func compare(_ a: [Double], _ b: [Double], eps: Double = 1e-9)
        -> (wins: Int, losses: Int, ties: Int, p: Double) {
        var wins = 0, losses = 0, ties = 0
        for (x, y) in zip(a, b) where x.isFinite && y.isFinite {
            if y > x + eps { wins += 1 } else if y < x - eps { losses += 1 } else { ties += 1 }
        }
        return (wins, losses, ties, p(wins: wins, losses: losses))
    }
}

/// Cohen's kappa between two label arrays of equal length over the four stages. NaN when degenerate.
func labelKappa(_ a: [String], _ b: [String]) -> Double { confusion(ref: a, pred: b).kappa }

/// Fraction of epochs that carry the same label in both arrays.
func labelAgreement(_ a: [String], _ b: [String]) -> Double {
    let n = min(a.count, b.count)
    return n == 0 ? .nan : Double(zip(a, b).filter { $0 == $1 }.count) / Double(n)
}

// MARK: - Strap reference (section J)

/// The strap's own band `sleep_state` against a hypnogram, sleep versus wake only: band 2 is sleep, 0 and 3 are
/// wake, and 1 ("still", genuinely ambiguous) is left out. The band carries no stages, and its code meanings are
/// inferred, so this is agreement with a proprietary black box and not accuracy.
func bandConfusion(_ labels: [String], band: [Int]) -> Confusion {
    var c = Confusion(classes: ["wake", "sleep"])
    let pred = toSleepWake(labels)
    for (i, b) in band.enumerated() where i < pred.count {
        guard b != 1 else { continue }
        c.add(ref: b == SleepStager.bandStateAsleep ? "sleep" : "wake", pred: pred[i])
    }
    return c
}

// MARK: - Sensitivity (section I)

/// A recipe parameter scaled by a factor. `skipWhenZero` keeps a switched-off candidate weight at zero
/// instead of reporting a sensitivity that is trivially nil.
struct Knob {
    let name: String
    let read: (RecipeConfig) -> Double
    let apply: (inout RecipeConfig, Double) -> Void

    static func scaled(_ name: String, _ kp: WritableKeyPath<RecipeConfig, Double>) -> Knob {
        Knob(name: name, read: { $0[keyPath: kp] }, apply: { $0[keyPath: kp] *= $1 })
    }

    /// Scales each stage's self-transition probability and renormalises the rest of its row, so the row still
    /// sums to one. The sticky diagonal is what decides bout length, which is why it is its own knob.
    static let selfLoops = Knob(
        name: "self-loop",
        read: { c in c.transition.keys.sorted().compactMap { c.transition[$0]?[$0] }.reduce(0, +) },
        apply: { c, f in
            for from in c.transition.keys {
                guard var row = c.transition[from], let diag = row[from] else { continue }
                let newDiag = min(0.999, diag * f)
                let rest = 1 - diag
                let others = rest > 0 ? (1 - newDiag) / rest : 0
                for (to, v) in row where to != from { row[to] = v * others }
                row[from] = newDiag
                c.transition[from] = row
            }
        })

    /// The recipe's tuned coefficients, one knob each. Priors are scaled as probabilities, which is the same
    /// multiplicative nudge the emission sees through the log.
    static let all: [Knob] = [
        scaled("priorLight", \.priorLight), scaled("priorDeep", \.priorDeep), scaled("priorRem", \.priorRem),
        scaled("priorAwake", \.priorAwake),
        scaled("deepGateThresh", \.deepGateThresh), scaled("deepGateSlope", \.deepGateSlope),
        scaled("jerkFloorMoveMult", \.jerkFloorMoveMult), scaled("jerkFloorGateMult", \.jerkFloorGateMult),
        scaled("motionGateBoost", \.motionGateBoost), scaled("respWeight", \.respWeight),
        scaled("awakeDeadzone", \.awakeDeadzone),
        scaled("deepZhv", \.deepZhv), scaled("remZhv", \.remZhv), scaled("awakeZmv", \.awakeZmv),
        scaled("remLatencyPenalty", \.remLatencyPenalty), scaled("remLatencyMinutes", \.remLatencyMinutes),
        selfLoops,
        scaled("rmssdWeight", \.rmssdWeight), scaled("lfhfWeight", \.lfhfWeight),
    ]
}

struct SensitivityRow {
    let knob: String
    let factor: Double
    /// kappa against the unscaled recipe, per night, as median and worst.
    let kappaMedian: Double
    let kappaMin: Double
    /// Mean over nights of the absolute change in minutes per stage.
    let meanAbsDeltaMin: [String: Double]
}

enum Sensitivity {
    /// Every knob of `cfg` that is on, scaled by each factor, restaged on every night and compared with `base`.
    static func run(inputs: [NightInput], base: [[String]], cfg: RecipeConfig, factors: [Double] = [0.9, 1.1],
                    knobs: [Knob] = Knob.all,
                    stage: (NightInput, RecipeConfig) -> [String] = Candidate.labels,
                    progress: (String) -> Void = { _ in }) -> [SensitivityRow] {
        var rows: [SensitivityRow] = []
        for knob in knobs where knob.read(cfg) != 0 {
            for factor in factors {
                var scaledCfg = cfg
                knob.apply(&scaledCfg, factor)
                var kappas: [Double] = []
                var deltas: [String: [Double]] = [:]
                for (i, input) in inputs.enumerated() {
                    let l = stage(input, scaledCfg)
                    kappas.append(labelKappa(base[i], l))
                    let m0 = stageMinutes(base[i]), m1 = stageMinutes(l)
                    for s in stageOrder { deltas[s, default: []].append(abs((m1[s] ?? 0) - (m0[s] ?? 0))) }
                }
                let finite = kappas.filter { $0.isFinite }
                rows.append(SensitivityRow(
                    knob: knob.name, factor: factor,
                    kappaMedian: median(finite), kappaMin: finite.min() ?? .nan,
                    meanAbsDeltaMin: deltas.mapValues { mean($0) }))
                progress(knob.name)
            }
        }
        return rows
    }
}

// MARK: - Damage to the inputs (section I)

struct Damage {
    let name: String
    let apply: (NightInput, UInt64) -> NightInput

    static let standard: [Damage] = [
        Damage(name: "10% of heart-rate seconds dropped") { n, seed in
            var o = n; o.hr = Perturb.dropHeartRate(n.hr, fraction: 0.10, seed: seed); return o },
        Damage(name: "10% of R-R beats dropped") { n, seed in
            var o = n; o.rr = Perturb.dropBeats(n.rr, fraction: 0.10, seed: seed); return o },
    ] + [15, 30, 60].map { minutes in
        Damage(name: "\(minutes)-min gravity hole mid-night") { n, _ in
            var o = n
            let mid = n.start + (n.end - n.start) / 2
            o.grav = Perturb.gravityHole(n.grav, from: mid - minutes * 30, to: mid + minutes * 30)
            return o }
    }
}

enum Robustness {
    /// kappa of each damaged restaging against the clean one, per night, for every damage in `damages`.
    static func run(inputs: [NightInput], clean: [[String]], cfg: RecipeConfig, damages: [Damage] = Damage.standard,
                    stage: (NightInput, RecipeConfig) -> [String] = Candidate.labels) -> [(damage: String, kappas: [Double])] {
        damages.map { d in
            let ks = inputs.enumerated().map { (i, input) in
                labelKappa(clean[i], stage(d.apply(input, UInt64(1_000 + i)), cfg))
            }
            return (d.name, ks)
        }
    }

    /// The window moved outward by `seconds` on both sides, and the labels cut back to the original interior.
    /// z-scores and percentiles are within the night, so a longer window can relabel epochs it shares with a
    /// shorter one; this is how much. Needs the streams to reach that far (the replay pads them).
    static func interiorAfterExtending(_ n: NightInput, by seconds: Int, cfg: RecipeConfig,
                                       stage: (NightInput, RecipeConfig) -> [String] = Candidate.labels) -> [String] {
        var wide = n
        wide.start -= seconds; wide.end += seconds
        let l = stage(wide, cfg)
        let lead = Int((Double(seconds) / epochSeconds).rounded())
        let count = epochCount(start: n.start, end: n.end)
        guard l.count >= lead + count else { return [] }
        return Array(l[lead..<(lead + count)])
    }
}

// MARK: - Export for the Smart Wake replay

enum StageExport {
    /// `N,<start>,<end>` then one `S,<start>,<end>,<stage>` per run of equal labels on the 30 s grid: the same
    /// line types `Tools/SmartWakeReplay` reads from a night file, so the candidate's stages can replace the
    /// stored V2 ones through `--stages-dir`.
    static func csv(start: Int, end: Int, labels: [String]) -> String {
        var out = "N,\(start),\(end)\n"
        var i = 0
        while i < labels.count {
            var j = i
            while j + 1 < labels.count && labels[j + 1] == labels[i] { j += 1 }
            let s = start + Int(Double(i) * epochSeconds)
            let e = min(end, start + Int(Double(j + 1) * epochSeconds))
            out += "S,\(s),\(e),\(labels[i])\n"
            i = j + 1
        }
        return out
    }
}
