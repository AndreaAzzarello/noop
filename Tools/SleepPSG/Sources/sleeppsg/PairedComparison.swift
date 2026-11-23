import Foundation
import SleepRecipe

// PairedComparison — one candidate against one baseline on the SAME subjects and the SAME epochs, reported per
// subject. Pooling 26 773 epochs hides who moved: a few long nights can carry a pooled kappa, and a change that
// helps three subjects a lot and hurts twenty a little can still look flat. Here every subject counts once.
//
// Everything is a plain function over label arrays, so each number is pinned by a hand-computed test.
//
// The inference is the sign test over subjects (Separation.signTestP), plus a percentile bootstrap interval on
// the mean per-subject change in kappa. Neither makes the subjects a sample of any wider population: 31
// laboratory nights of one dataset say how a recipe does on THIS cohort, and the report says so.

struct StageMinutes {
    /// Mean over subjects of (candidate minutes - baseline minutes) in this stage.
    let meanShift: Double
    /// The largest single-subject |shift|.
    let worstShift: Double
    /// Mean over subjects of |baseline minutes - PSG minutes| and of |candidate minutes - PSG minutes|.
    let errorBase: Double
    let errorCand: Double
    /// Subjects whose minutes in this stage move closer to / farther from the PSG's.
    let closer: Int
    let farther: Int
}

struct PairedResult {
    let subjects: Int
    /// Per subject, aligned: kappa against the PSG of the baseline and of the candidate. NaN where a subject's
    /// night carries one class only (kappa is undefined there); such subjects are left out of the kappa
    /// statistics and still count in the minutes.
    let kappaBase: [Double]
    let kappaCand: [Double]
    let wins: Int           // candidate kappa above baseline
    let losses: Int
    let ties: Int
    let signP: Double
    let meanDelta: Double
    let ciLow: Double
    let ciHigh: Double
    let stages: [String: StageMinutes]
}

enum PairedComparison {
    /// kappa differences smaller than this count as a tie (a label-for-label identical hypnogram gives 0 exactly).
    static let tieEpsilon = 1e-9

    /// `truth`, `base` and `cand` hold one label array per subject, aligned on the PSG-scored epochs.
    static func compare(truth: [[String]], base: [[String]], cand: [[String]],
                        epochSeconds: Double = 30, bootstrap: Int = 4000, seed: UInt64 = 0x51_6E7E57) -> PairedResult {
        precondition(truth.count == base.count && base.count == cand.count, "compare: one array per subject")
        var kb: [Double] = [], kc: [Double] = []
        for i in truth.indices {
            kb.append(confusion(ref: truth[i], pred: base[i]).kappa)
            kc.append(confusion(ref: truth[i], pred: cand[i]).kappa)
        }
        let deltas = zip(kb, kc).compactMap { b, c -> Double? in (b.isNaN || c.isNaN) ? nil : c - b }
        let wins = deltas.filter { $0 > tieEpsilon }.count
        let losses = deltas.filter { $0 < -tieEpsilon }.count

        var lo = Double.nan, hi = Double.nan
        if deltas.count > 1 && bootstrap > 0 {
            var rng = SplitMix64(seed: seed)
            var means: [Double] = []
            means.reserveCapacity(bootstrap)
            for _ in 0..<bootstrap {
                var sum = 0.0
                for _ in deltas.indices { sum += deltas[rng.int(0, deltas.count - 1)] }
                means.append(sum / Double(deltas.count))
            }
            means.sort()
            lo = means[Int(Double(bootstrap) * 0.025)]
            hi = means[min(bootstrap - 1, Int(Double(bootstrap) * 0.975))]
        }

        let minutesPerEpoch = epochSeconds / 60
        var stages: [String: StageMinutes] = [:]
        for st in stageOrder {
            var shift: [Double] = [], errB: [Double] = [], errC: [Double] = []
            for i in truth.indices {
                func minutes(_ labels: [String]) -> Double { Double(labels.filter { $0 == st }.count) * minutesPerEpoch }
                let t = minutes(truth[i]), b = minutes(base[i]), c = minutes(cand[i])
                shift.append(c - b); errB.append(abs(b - t)); errC.append(abs(c - t))
            }
            stages[st] = StageMinutes(
                meanShift: mean(shift), worstShift: shift.map { abs($0) }.max() ?? 0,
                errorBase: mean(errB), errorCand: mean(errC),
                closer: zip(errB, errC).filter { $1 < $0 - 1e-9 }.count,
                farther: zip(errB, errC).filter { $1 > $0 + 1e-9 }.count)
        }
        return PairedResult(subjects: truth.count, kappaBase: kb, kappaCand: kc, wins: wins, losses: losses,
                            ties: deltas.count - wins - losses,
                            signP: Separation.signTestP(positive: wins, negative: losses),
                            meanDelta: mean(deltas), ciLow: lo, ciHigh: hi, stages: stages)
    }
}
