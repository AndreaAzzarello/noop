import Foundation
import SleepRecipe
import StrandAnalytics
import WhoopProtocol

// Sections H-K: the candidate recipes (Tools/SleepPSG `Variants`) replayed over the same nights as A-G.
//
// WHAT THESE SECTIONS CAN AND CANNOT SHOW. They show how a candidate DIFFERS from the incumbent, whether its
// hypnograms keep the shape sleep has, how much they move under small changes to the recipe and to the data,
// and how they sit against the strap's own sleep/wake verdict. They cannot show that a candidate is more
// accurate: there is no per-epoch reference for stages on this device, the plausibility bands are partly
// circular (the incumbent already carries "deep early, REM late" priors), the strap band carries no stages and
// its code meanings are inferred, and the Smart Wake agreement in `Tools/SmartWakeReplay` is circular because
// both sides derive from the same recipe. Every table below is headed accordingly.
//
// Nights are numbered, not dated: the point is the distribution, and a date adds nothing but exposure.

/// One replay of every night under every variant, computed once and read by all four sections.
struct CandidateRun {
    let variants: [Variant]
    /// `labels[variant][night]`, per-epoch on the bench grid.
    let labels: [[[String]]]
    /// Wall-clock milliseconds the staging took, `ms[variant][night]`.
    let ms: [[Double]]

    static func replay(nights: [Night], variants: [Variant]) -> CandidateRun {
        var labels: [[[String]]] = [], ms: [[Double]] = []
        for v in variants {
            var l: [[String]] = [], t: [Double] = []
            for nt in nights {
                let r = Candidate.timedLabels(nt.input, v.config)
                l.append(r.labels); t.append(r.ms)
                FileHandle.standardError.write(Data(".".utf8))
            }
            labels.append(l); ms.append(t)
            FileHandle.standardError.write(Data(" \(v.name)\n".utf8))
        }
        return CandidateRun(variants: variants, labels: labels, ms: ms)
    }
}

enum Sections {

    static let metricOrder: [(key: String, title: String)] = [
        ("lightPct", "light % of TST"), ("deepPct", "deep % of TST"), ("remPct", "REM % of TST"),
        ("wasoPctOfPeriod", "wake % of period"), ("deepFirstHalf", "deep in 1st half"),
        ("remSecondHalf", "REM in 2nd half"), ("firstRemLatencyMin", "1st REM latency min"),
        ("remPeriodMin", "REM period spacing min"), ("transitionsPerHour", "transitions / hour"),
        ("shortBoutShare", "bouts < 3 min share"),
    ]

    private static func cell(_ v: Double?, _ w: Int, _ p: Int) -> String {
        guard let v, v.isFinite else { return String(repeating: " ", count: w - 1) + "-" }
        return f(v, w, p)
    }

    private static func name(_ v: Variant, _ i: Int) -> String {
        (i == 0 ? "incumbent" : v.name).padding(toLength: 30, withPad: " ", startingAt: 0)
    }

    private static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }

    // MARK: H

    static func printH(nights: [Night], run: CandidateRun, bands: PlausibilityBands) {
        let metrics = run.labels.map { $0.map { NightMetrics.of($0) } }
        print("""

        ================================================================================
        H. INTERNAL CONSISTENCY — what each hypnogram looks like as a night
        ================================================================================
        Bands: \(bands.source)
        This says whether a night has the SHAPE sleep has. It does not say any epoch is right, and it is partly
        circular: the incumbent already carries "deep early, REM late" priors and a REM-latency guard, so passing
        those two bands is partly the prior speaking. Use it to catch a candidate that breaks the shape.
        """)
        let identical = zip(run.labels[0], nights).filter { $0 == $1.v2 }.count
        print("port check: \(identical) of \(nights.count) nights label-identical between the recipe port and the shipped stager" +
              (identical == nights.count ? "" : "   <-- the port has drifted from SleepStagerV2; read nothing below as the shipped recipe"))

        print("\nINCUMBENT, per night (night number, not date)")
        print("night hours   TST  light  deep   REM  wake%  d1st  r2nd 1stREM  tr/h short% remGap  in-band")
        for (i, nt) in nights.enumerated() {
            let m = metrics[0][i]
            guard m.hasSleep else { print("\(pad(String(i + 1), 5)) \(f(nt.row.durMin / 60, 5, 1))   no sustained sleep"); continue }
            let s = bands.score(m)
            print("\(pad(String(i + 1), 5)) \(f(nt.row.durMin / 60, 5, 1)) \(f(m.tstMin, 5, 0)) \(f(m.lightPct, 6, 1)) \(f(m.deepPct, 5, 1)) \(f(m.remPct, 5, 1)) "
                + "\(f(m.wasoPctOfPeriod, 6, 1)) \(cell(m.deepFirstHalf, 5, 2)) \(cell(m.remSecondHalf, 5, 2)) \(cell(m.firstRemLatencyMin, 6, 0)) "
                + "\(f(m.transitionsPerHour, 5, 1)) \(f(m.shortBoutShare * 100, 6, 0)) \(cell(m.remPeriodMin, 6, 0))  \(s.inside)/\(s.judged)")
        }

        print("\nACROSS NIGHTS, per variant: median [p10 .. p90]; nights inside the band / nights judged")
        for (vi, v) in run.variants.enumerated() {
            print("\n  \(name(v, vi))")
            for (key, title) in metricOrder {
                let vals = metrics[vi].compactMap { $0.hasSleep ? $0.values[key] ?? nil : nil }.filter { $0.isFinite }
                guard !vals.isEmpty else { print("    \(pad(title, 24)) no night had a value"); continue }
                let inside = vals.filter { bands.contains(key, $0) == true }.count
                let range = bands.ranges[key].map { "band \(f($0.lowerBound, 0, 2))..\(f($0.upperBound, 0, 2))" } ?? "no band"
                print("    \(pad(title, 24)) \(f(median(vals), 7, 2)) [\(f(percentile(vals, 0.1), 7, 2)) .. \(f(percentile(vals, 0.9), 7, 2))]  \(pad(range, 18)) inside \(inside)/\(vals.count)")
            }
        }

        // The C4 gate. Fragmentation is the only thing that would justify a minimum-bout-length decoder.
        let inc = metrics[0].filter { $0.hasSleep }
        func outside(_ key: String) -> (above: Int, below: Int, n: Int) {
            guard let r = bands.ranges[key] else { return (0, 0, 0) }
            let v = inc.compactMap { $0.values[key] ?? nil }.filter { $0.isFinite }
            return (v.filter { $0 > r.upperBound }.count, v.filter { $0 < r.lowerBound }.count, v.count)
        }
        let tr = outside("transitionsPerHour"), sb = outside("shortBoutShare")
        print("""

        C4 GATE (a minimum-bout-length decoder is warranted only if the incumbent is too fragmented):
          transitions / hour  above band \(tr.above) / below band \(tr.below) of \(tr.n) nights
          short-bout share    above band \(sb.above) / below band \(sb.below) of \(sb.n) nights
          \(bands.source.hasPrefix("broad") ? "The band in use is the author's broad fallback, not a PSG-derived one: read this as indicative and take the decision only against PSG bands." : "Band is PSG-derived.")
        """)
    }

    // MARK: I

    static func printI(nights: [Night], run: CandidateRun) {
        let inputs = nights.map { $0.input }
        print("""

        ================================================================================
        I. SENSITIVITY AND ROBUSTNESS — how much the hypnogram moves
        ================================================================================
        These are necessary conditions, not evidence of accuracy: a recipe can be perfectly stable and perfectly
        wrong. Kappa is against the same recipe's own unperturbed output, four stages, per night.
        """)

        // Run-to-run.
        var same = 0
        for (i, nt) in nights.enumerated() where Candidate.labels(nt.input, run.variants[0].config) == run.labels[0][i] { same += 1 }
        print("\nRUN-TO-RUN (incumbent restaged on the same input): \(same) of \(nights.count) nights identical")

        // Recipe sensitivity.
        print("\nRECIPE SENSITIVITY — each coefficient scaled by -10% and +10%, kappa vs the unscaled recipe")
        print("  knob                 factor  kappa med  kappa worst   |Δ min| wake  light   deep    rem   flag")
        func printRows(_ rows: [SensitivityRow], prefix: String) {
            for r in rows {
                let d = r.meanAbsDeltaMin
                let flag = r.kappaMedian < 0.90 ? "fragile (median kappa < 0.90)" : ""
                print("  \(pad(prefix + r.knob, 20)) \(f(r.factor, 6, 2)) \(f(r.kappaMedian, 9, 3)) \(f(r.kappaMin, 11, 3))   "
                    + "\(f(d["wake"] ?? .nan, 12, 1)) \(f(d["light"] ?? .nan, 6, 1)) \(f(d["deep"] ?? .nan, 6, 1)) \(f(d["rem"] ?? .nan, 6, 1))   \(flag)")
            }
        }
        for (vi, v) in run.variants.enumerated() {
            let candidateOnly = ["rmssdWeight", "lfhfWeight"]
            let knobs = vi == 0 ? Knob.all : Knob.all.filter { candidateOnly.contains($0.name) }
            guard !knobs.isEmpty else { continue }
            let rows = Sensitivity.run(inputs: inputs, base: run.labels[vi], cfg: v.config, knobs: knobs) { _ in
                FileHandle.standardError.write(Data(".".utf8))
            }
            FileHandle.standardError.write(Data(" sensitivity \(v.name)\n".utf8))
            if vi > 0 { print("  -- \(v.name): only the knobs the candidate adds; the shared ones read as the incumbent's") }
            printRows(rows, prefix: vi == 0 ? "" : String(v.name.prefix(3)) + "·")
        }

        // Window edge.
        print("\nWINDOW EDGE — the session window pushed outward on both sides, labels cut back to the original interior")
        print("  (z-scores and percentiles are within the night, so a longer window can relabel shared epochs)")
        print("  variant                         ±min  kappa med  kappa worst  agreement mean")
        for (vi, v) in run.variants.enumerated() {
            for minutes in [15, 30] {
                var ks: [Double] = [], ag: [Double] = []
                for (i, nt) in nights.enumerated() {
                    let cut = Robustness.interiorAfterExtending(nt.input, by: minutes * 60, cfg: v.config)
                    guard !cut.isEmpty else { continue }
                    ks.append(labelKappa(run.labels[vi][i], cut)); ag.append(labelAgreement(run.labels[vi][i], cut))
                }
                let k = ks.filter { $0.isFinite }
                print("  \(name(v, vi)) \(f(Double(minutes), 4, 0) ) \(f(median(k), 9, 3)) \(f(k.min() ?? .nan, 11, 3)) \(f(mean(ag) * 100, 14, 1))%")
            }
        }

        // Data damage.
        print("\nDATA DAMAGE — restaged after damaging the inputs (seeded, identical damage for every variant), kappa vs own clean run")
        print("  variant                         damage                              kappa med  kappa worst")
        for (vi, v) in run.variants.enumerated() {
            let results = Robustness.run(inputs: inputs, clean: run.labels[vi], cfg: v.config)
            FileHandle.standardError.write(Data(" damage \(v.name)\n".utf8))
            for r in results {
                let k = r.kappas.filter { $0.isFinite }
                print("  \(name(v, vi)) \(pad(r.damage, 34)) \(f(median(k), 9, 3)) \(f(k.min() ?? .nan, 11, 3))")
            }
        }
    }

    // MARK: J

    static func printJ(nights: [Night], run: CandidateRun, csv: (csv: Int, withRawStreams: Int)) {
        let banded = nights.indices.filter { !nights[$0].band.isEmpty }
        print("""

        ================================================================================
        J. THE STRAP'S OWN VERDICT — band sleep_state, sleep versus wake only
        ================================================================================
        Band 2 -> sleep, band 0/3 -> wake, band 1 ("still") excluded. The strap scores no stages, its code
        meanings are inferred from the firmware, and kappa against it is agreement with a black box, not accuracy.
        Nights with a band stream: \(banded.count) of \(nights.count).
        """)
        guard !banded.isEmpty else { print("  no night carries a band stream"); return }
        print("  variant                         pooled kappa  per-night kappa med   wake sens  wake spec  acc")
        for (vi, v) in run.variants.enumerated() {
            var pooled = Confusion(classes: ["wake", "sleep"]), per: [Double] = []
            for i in banded {
                let c = bandConfusion(run.labels[vi][i], band: nights[i].band)
                pooled.merge(c); per.append(c.kappa)
            }
            let (sens, spec, _) = pooled.sensSpec("wake")
            print("  \(name(v, vi)) \(f(pooled.kappa, 12, 3)) \(f(median(per.filter { $0.isFinite }), 19, 3))   \(f(sens * 100, 8, 1))%  \(f(spec * 100, 8, 1))%  \(f(pooled.accuracy * 100, 4, 1))%")
        }
        print("""

        WHOOP CSV TOTALS: \(csv.csv) imported night(s) carry per-stage minutes; \(csv.withRawStreams) of them also have recorded heart rate.
        \(csv.withRawStreams == 0 ? "Nothing to score: a CSV night has totals only, and none overlaps a recorded stream, so no stage-minute error is computed here." : "Overlapping nights exist, but this bench has no scorer for them yet: the dictionary holds minutes per stage only.")
        """)
    }

    // MARK: K

    static func printK(nights: [Night], run: CandidateRun, bands: PlausibilityBands) {
        print("""

        ================================================================================
        K. A/B — each candidate against the incumbent, same nights
        ================================================================================
        This table says how a candidate DIFFERS and whether it moves the internal measures. It does not say it is
        more accurate. A positive row here is a reason to test on PSG with beat-to-beat intervals, not a result.
        Nights: \(nights.count). Sign test: exact two-sided, ties dropped.
        """)
        let inc = run.labels[0]
        let incMetrics = inc.map { NightMetrics.of($0) }
        for vi in 1..<max(1, run.variants.count) {
            let v = run.variants[vi]
            let cand = run.labels[vi]
            let metrics = cand.map { NightMetrics.of($0) }
            print("\n--- \(v.name)  (\(v.note))")

            let ks = nights.indices.map { labelKappa(inc[$0], cand[$0]) }.filter { $0.isFinite }
            var pooled = Confusion(classes: stageOrder)
            for i in nights.indices { pooled.merge(confusion(ref: inc[i], pred: cand[i])) }
            let changed = nights.indices.filter { inc[$0] != cand[$0] }.count
            print("  agreement with incumbent: pooled kappa \(f(pooled.kappa, 0, 3)), per-night kappa median \(f(median(ks), 0, 3)) worst \(f(ks.min() ?? .nan, 0, 3)); nights with any change \(changed) of \(nights.count)")

            print("  minutes per stage, candidate minus incumbent:      wake   light    deep     rem")
            var perStage: [String: [Double]] = [:]
            for i in nights.indices {
                let a = stageMinutes(inc[i]), b = stageMinutes(cand[i])
                for s in stageOrder { perStage[s, default: []].append((b[s] ?? 0) - (a[s] ?? 0)) }
            }
            func row(_ label: String, _ g: ([Double]) -> Double) {
                print("    \(pad(label, 48)) \(f(g(perStage["wake"] ?? []), 5, 1)) \(f(g(perStage["light"] ?? []), 7, 1)) \(f(g(perStage["deep"] ?? []), 7, 1)) \(f(g(perStage["rem"] ?? []), 7, 1))")
            }
            row("mean over nights") { mean($0) }
            row("worst night (largest |change|)") { vals in vals.max { abs($0) < abs($1) } ?? .nan }

            // Internal measures: fraction of judged metrics inside the band, per night.
            func frac(_ m: NightMetrics) -> Double {
                guard m.hasSleep else { return .nan }
                let s = bands.score(m); return s.judged == 0 ? .nan : Double(s.inside) / Double(s.judged)
            }
            let fa = incMetrics.map(frac), fb = metrics.map(frac)
            let c1 = Sign.compare(fa, fb)
            print("  share of bands each night sits inside: incumbent \(f(mean(fa.filter { $0.isFinite }) * 100, 0, 1))% -> candidate \(f(mean(fb.filter { $0.isFinite }) * 100, 0, 1))%; "
                + "nights better/worse/tie \(c1.wins)/\(c1.losses)/\(c1.ties), p = \(f(c1.p, 0, 3))   [\(bands.source.hasPrefix("broad") ? "broad fallback bands" : "PSG bands")]")
            for key in ["deepPct", "remPct", "transitionsPerHour"] {
                let a = incMetrics.compactMap { $0.hasSleep ? $0.values[key] ?? nil : nil }
                let b = metrics.compactMap { $0.hasSleep ? $0.values[key] ?? nil : nil }
                print("    \(pad(key, 20)) median \(f(median(a), 0, 2)) -> \(f(median(b), 0, 2))")
            }

            // Strap sleep/wake agreement, per night.
            let banded = nights.indices.filter { !nights[$0].band.isEmpty }
            if !banded.isEmpty {
                let ka = banded.map { bandConfusion(inc[$0], band: nights[$0].band).kappa }
                let kb = banded.map { bandConfusion(cand[$0], band: nights[$0].band).kappa }
                let c2 = Sign.compare(ka, kb)
                print("  strap sleep/wake kappa per night: median \(f(median(ka.filter { $0.isFinite }), 0, 3)) -> \(f(median(kb.filter { $0.isFinite }), 0, 3)); nights better/worse/tie \(c2.wins)/\(c2.losses)/\(c2.ties), p = \(f(c2.p, 0, 3))")
            }

            // CPU.
            let mi = median(run.ms[0]), mc = median(run.ms[vi])
            print("  staging time per night (median, release build): incumbent \(f(mi, 0, 0)) ms -> candidate \(f(mc, 0, 0)) ms (x\(f(mc / max(mi, 1e-9), 0, 2)))")
        }
        if run.variants.count == 1 { print("\n  no candidate variant selected (--variants)") }
    }
}
