import Foundation
import SleepRecipe
import StrandAnalytics
import WhoopProtocol

// sleeppsg — score NOOP's shipped sleep stager against polysomnography.
//
// USAGE:  sleeppsg --dataset /path/to/sleep-accel-1.0.0 [--section all] [--csv out.csv] [--subjects N]
//         sleeppsg --section port                        (no dataset needed — the port check alone)
//
// The dataset lives outside this repository and is always an argument. Nothing is written to it.

struct Args {
    var dataset: String?
    var section = "all"
    var csv: String?
    var bandsOut: String?
    var slpdb: String?
    var subjects: Int?
    var seed: UInt64 = PortValidation.defaultSeed
}
var a = Args()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() {
    switch k {
    case "--dataset": a.dataset = it.next()
    case "--section": a.section = it.next() ?? a.section
    case "--csv": a.csv = it.next()
    case "--bands-out": a.bandsOut = it.next()
    case "--slpdb": a.slpdb = it.next()
    case "--subjects": a.subjects = Int(it.next() ?? "")
    case "--seed": a.seed = UInt64(it.next() ?? "") ?? a.seed
    case "-h", "--help":
        print("""
        usage: sleeppsg --dataset <sleep-accel root> [--section all|port|baseline|strata|rem|variants|candidates|priors]
                        [--subjects N] [--csv <path>] [--seed <n>] [--bands-out <path>]
               sleeppsg --section rrstage --slpdb <dir written by scripts/slpdb_export.py>
               sleeppsg --dataset <sleep-accel root> --section signtest|dropout|priorsoff

          --dataset   PhysioNet sleep-accel v1.0.0, extracted. See README.md for the download step and the
                      attribution its licence requires. Never committed; read-only here.
          --slpdb     the CSV export of the MIT-BIH Polysomnographic Database (`--section rrstage` only; it needs
                      no sleep-accel dataset).
          --section   which report to print. `signtest` (C5b against the incumbent, subject by subject), `dropout`
                      (seeded gravity / heart-rate loss, C1 and C5b against PSG) and `priorsoff` (cycle prior and
                      REM guard ablation) are never part of `all`: run them by name. `port` needs no dataset. `candidates` is section 6's table for the
                      proposals under evaluation (C1, C3, C5) instead of the provenance variants.
          --bands-out write the p10..p90 plausibility bands of the PSG hypnograms (for `sleepbench --bands`)
          --subjects  score only the first N subject ids (a fast smoke run; full cohort is the default).
        """)
        exit(0)
    default: FileHandle.standardError.write(Data("unknown argument \(k)\n".utf8)); exit(2)
    }
}

let wantAll = a.section == "all"
func want(_ s: String) -> Bool { wantAll || a.section == s }

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// 1. PORT VALIDATION
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("port") {
    print("""

    ================================================================================
    1. PORT VALIDATION — does this harness run the SHIPPED recipe?
    ================================================================================
    Every baseline number below comes from `StrandAnalytics.SleepStagerV2.stageSession` directly: the file
    that ships in the app, compiled from `Packages/`, called with no reimplementation in between. The
    VARIANT rows cannot work that way — `SleepStagerV2` holds its constants as `static let`s — so they run
    through `V2Recipe`, a knob-for-knob port in this tool. This section is the check that the port and the
    shipped stager are the same recipe. It runs in `swift test`, and therefore in CI, with no dataset.
    """)
    let r = PortValidation.run(seed: a.seed)
    print("""
    nights            \(r.nights)  (\(r.randomNights) randomised + \(r.degenerateNights) degenerate)
    epoch labels      \(r.matchingEpochs)/\(r.epochs) identical
    verdict           \(r.ok ? "PASS — the port reproduces the shipped stager exactly" : "FAIL")
    """)
    if !r.ok {
        for d in r.divergences.prefix(20) {
            print("  divergence  \(d.night) epoch \(d.epochIndex): shipped=\(d.shipped) port=\(d.port)")
        }
        FileHandle.standardError.write(Data("port validation FAILED — variant numbers are not trustworthy\n".utf8))
        exit(1)
    }
}

if a.section == "port" { exit(0) }

// The R-R / stage separation runs on a different dataset (MIT-BIH Polysomnographic, exported to CSV) and needs
// nothing from sleep-accel, so it is handled before the sleep-accel guard below.
if a.section == "rrstage" {
    guard let dir = a.slpdb else {
        FileHandle.standardError.write(Data("--section rrstage needs --slpdb <export dir> (scripts/slpdb_export.py)\n".utf8))
        exit(2)
    }
    exit(RRStageReport.run(dir: (dir as NSString).expandingTildeInPath) ? 0 : 1)
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Dataset
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

guard let datasetArg = a.dataset else {
    FileHandle.standardError.write(Data("""
    --dataset is required for every section except `port`.
    See Tools/SleepPSG/README.md for the download step and the attribution the licence requires.

    """.utf8))
    exit(2)
}
guard let root = SleepAccel.resolveRoot(datasetArg) else {
    FileHandle.standardError.write(Data("no `labels/` directory under \(datasetArg) — is that the sleep-accel root?\n".utf8))
    exit(2)
}

var ids = SleepAccel.subjectIDs(root: root)
if let n = a.subjects { ids = Array(ids.prefix(n)) }
// Loaded concurrently — the motion files run to tens of megabytes of text each and the read dominates the
// whole run. Order is restored from `ids` afterwards so the report is identical however the threads finish.
var loaded = [PSGSubject?](repeating: nil, count: ids.count)
loaded.withUnsafeMutableBufferPointer { buf in
    let out = buf
    DispatchQueue.concurrentPerform(iterations: ids.count) { i in
        out[i] = SleepAccel.load(root: root, id: ids[i])
    }
}
let subjects: [PSGSubject] = loaded.compactMap { $0 }
guard !subjects.isEmpty else {
    FileHandle.standardError.write(Data("no scorable subjects under \(root)\n".utf8)); exit(1)
}

let totalScored = subjects.reduce(0) { $0 + $1.scoredEpochs }
print("""

================================================================================
2. DATASET
================================================================================
PhysioNet sleep-accel v1.0.0 — Walch, Huang, Forger & Goldstein, SLEEP 42(12) zsz180 (2019).
Licence: Open Data Commons Attribution v1.0. Root: \(root)

subjects              \(subjects.count)
PSG-scored epochs     \(totalScored)
scored night length   median \(f(median(subjects.map { $0.scoredMinutes }), 6, 1)) min   \
range \(f(subjects.map { $0.scoredMinutes }.min() ?? .nan, 5, 1))–\(f(subjects.map { $0.scoredMinutes }.max() ?? .nan, 5, 1)) min

The R-R stream is EMPTY for every subject — this dataset carries no beat-to-beat intervals — so the
recipe's RSA respiration term returns nil on every epoch and contributes exactly 0.0 to every emission.
Five of the recipe's six inputs are live here; the sixth is silent, not wrong.
""")

// Truth / prediction on the shared 30 s grid, restricted to PSG-scored epochs.
struct Scored {
    let subject: PSGSubject
    let truth: [String]
    let pred: [String]
    /// Full-grid arrays (including unscored epochs) — latency is a property of the hypnogram, not of the
    /// scored subset, so it is measured before masking.
    let fullPred: [String]
    let fullTruth: [String?]
}

func score(_ s: PSGSubject, using stage: (PSGSubject) -> [StageSegment]) -> Scored {
    let segs = stage(s)
    let pred = epochLabels(segs, start: s.start, end: s.end)
    var t: [String] = [], p: [String] = []
    for i in 0..<min(s.truth.count, pred.count) {
        guard let tv = s.truth[i] else { continue }
        t.append(tv); p.append(pred[i])
    }
    return Scored(subject: s, truth: t, pred: p, fullPred: pred, fullTruth: s.truth)
}

/// The SHIPPED stager — `StrandAnalytics.SleepStagerV2`, not the port.
func stageShipped(_ s: PSGSubject) -> [StageSegment] {
    SleepStagerV2.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr, rr: [], resp: [])
}
func stageVariant(_ cfg: RecipeConfig) -> (PSGSubject) -> [StageSegment] {
    { s in V2Recipe.stageSession(start: s.start, end: s.end, grav: s.grav, hr: s.hr,
                                 rr: [], resp: [], cfg: cfg) }
}

let shipped = subjects.map { score($0, using: stageShipped) }

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Reporting helpers
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

struct Summary {
    var conf = Confusion()
    var kappa: Double { conf.kappa }
    var accuracy: Double { conf.accuracy }
    var predPct: [String: Double] = [:]
    var truthPct: [String: Double] = [:]
    var latencyPred: [Double] = []
    var latencyTruth: [Double] = []
    var latencyPairsPred: [Double] = []
    var latencyPairsTruth: [Double] = []
    /// Per-subject kappa, excluding any subject whose scored night carries only one class (kappa is
    /// undefined there, and letting a NaN into the mean would quietly void the whole column).
    var subjectKappa: [Double] = []
    var noRemNights = 0
}

func summarise(_ rows: [Scored]) -> Summary {
    var s = Summary()
    var predAcc = [String: Double](), truthAcc = [String: Double]()
    for r in rows {
        var c = Confusion()
        for i in 0..<r.truth.count { c.add(ref: r.truth[i], pred: r.pred[i]) }
        s.conf.merge(c)
        if !c.kappa.isNaN { s.subjectKappa.append(c.kappa) }
        let pp = stagePercentages(r.pred), tp = stagePercentages(r.truth)
        for k in stageOrder { predAcc[k, default: 0] += pp[k]!; truthAcc[k, default: 0] += tp[k]! }
        // Latency: both on the FULL 30 s grid, so both are wall-clock minutes from that night's own
        // sleep onset. The truth column skips unscored epochs when looking for onset and for REM but
        // still counts their slots — collapsing them first would shorten only the truth latency, by
        // however much of the night the technician left unscored.
        let lp = firstRemLatencyMinutes(r.fullPred)
        let lt = firstRemLatencyMinutes(r.fullTruth)
        if let v = lp { s.latencyPred.append(v) } else { s.noRemNights += 1 }
        if let v = lt { s.latencyTruth.append(v) }
        if let x = lp, let y = lt { s.latencyPairsPred.append(x); s.latencyPairsTruth.append(y) }
    }
    let n = Double(rows.count)
    for k in stageOrder { s.predPct[k] = predAcc[k]! / n; s.truthPct[k] = truthAcc[k]! / n }
    return s
}

/// Stage fractions computed over POOLED epochs rather than as a mean of per-night percentages. Both are
/// reported: the pooled number is what a cohort-level "% of night" means, the per-subject mean is what a
/// clinician comparing individuals would use, and they differ whenever night lengths differ.
func pooledPct(_ rows: [Scored], _ pick: (Scored) -> [String]) -> [String: Double] {
    var all: [String] = []
    for r in rows { all.append(contentsOf: pick(r)) }
    return stagePercentages(all)
}

let sh = summarise(shipped)
let pooledPred = pooledPct(shipped) { $0.pred }
let pooledTruth = pooledPct(shipped) { $0.truth }

if want("baseline") {
    print("""

    ================================================================================
    3. SHIPPED SleepStagerV2 vs PSG TRUTH
    ================================================================================
    Four-class agreement over every PSG-scored epoch. `SleepStagerV2` fits no parameters to data — every
    coefficient is fixed a priori — so there is no train/test split to make here: the recipe sees each
    subject exactly once and has never seen any of them. The leave-one-subject-out machinery in section 6
    exists for the fitted comparison models, which do need it.

    epochs scored     \(sh.conf.total)
    accuracy          \(f(sh.accuracy * 100, 6, 2)) %
    Cohen's kappa     \(f(sh.kappa, 6, 3))   (per-subject mean \(f(mean(sh.subjectKappa), 6, 3)) ± \(f(sd(sh.subjectKappa), 5, 3)))

    per stage             precision   recall       F1   support
    """)
    for st in stageOrder {
        let p = sh.conf.prf(st)
        print("      \(st.padding(toLength: 18, withPad: " ", startingAt: 0))\(f(p.precision, 8, 3)) \(f(p.recall, 8, 3)) \(f(p.f1, 8, 3))   \(p.support)")
    }
    print("""

    STAGE FRACTIONS — reported as a first-class result, not an appendix.
    Kappa does not constrain them: PR #348 raised kappa on all three of its benchmarks and was reverted
    48 h later for re-scoring a healthy night from 6 % to 23 % awake.

    stage        predicted %   truth %      bias pp   (pooled over all scored epochs)
    """)
    for st in stageOrder {
        print("      \(st.padding(toLength: 10, withPad: " ", startingAt: 0))\(f(pooledPred[st]!, 10, 2))\(f(pooledTruth[st]!, 10, 2))\(f(pooledPred[st]! - pooledTruth[st]!, 12, 2))")
    }
    print("\n    stage        predicted %   truth %      bias pp   (mean of per-subject percentages)")
    for st in stageOrder {
        print("      \(st.padding(toLength: 10, withPad: " ", startingAt: 0))\(f(sh.predPct[st]!, 10, 2))\(f(sh.truthPct[st]!, 10, 2))\(f(sh.predPct[st]! - sh.truthPct[st]!, 12, 2))")
    }
    print("""

    FIRST-REM LATENCY — minutes from staged sleep onset to the first REM epoch.
    nights with no REM in the prediction: \(sh.noRemNights) of \(shipped.count)

                        predicted     truth
      median          \(f(median(sh.latencyPred), 10, 1))\(f(median(sh.latencyTruth), 10, 1))  min
      mean            \(f(mean(sh.latencyPred), 10, 1))\(f(mean(sh.latencyTruth), 10, 1))  min
      MAE (paired)    \(f(mae(zip(sh.latencyPairsPred, sh.latencyPairsTruth).map { $0 - $1 }), 10, 1))            min  (n = \(sh.latencyPairsPred.count))
    """)

    // A harness that replaces a deleted one has to say whether it is the same instrument. These are the
    // figures the previous harness reported on this dataset. They are printed as a self-check, NOT as a
    // target: nothing in this tool is tuned to hit them, and where they disagree the disagreement is the
    // finding. See `Variants.preNine30Guard` for what explains the prediction-side gap.
    let ref: [(String, Double, Double, Int)] = [
        ("subjects", Double(subjects.count), 31, 0),
        ("PSG-scored epochs", Double(sh.conf.total), 26773, 0),
        ("kappa (4-class)", sh.kappa, 0.349, 3),
        ("REM F1", sh.conf.prf("rem").f1, 0.515, 3),
        ("REM % of night", sh.predPct["rem"]!, 20.8, 2),
        ("deep % predicted", sh.predPct["deep"]!, 19.25, 2),
        ("deep % truth", sh.truthPct["deep"]!, 14.76, 2),
        ("first-REM predicted, min", median(sh.latencyPred), 142.0, 1),
        ("first-REM truth, min", median(sh.latencyTruth), 88.5, 1),
    ]
    print("""

    SELF-CHECK against the previous harness's reported figures
    Printed to expose disagreement, not to be matched. Nothing here is tuned to these numbers. Stage
    fractions use the per-subject-mean convention, which is the one those figures were reported on.

    quantity                        measured   previously      delta
    """)
    for (name, got, want, dp) in ref {
        print("      \(name.padding(toLength: 28, withPad: " ", startingAt: 0))\(f(got, 9, dp))\(f(want, 13, dp))\(f(got - want, 11, dp))")
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Night-length stratification
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("strata") {
    print("""

    ================================================================================
    4. STRATIFIED BY NIGHT LENGTH
    ================================================================================
    Pooling hides a coupling. On one wearer's own nights, `SleepStagerV2` emits more REM as a fraction of
    sleep the longer the night runs — corr(total sleep, REM %) = +0.579 — traced to the REM-latency guard
    being a fixed 60-minute penalty, which therefore covers a third of a short night and a tenth of a long
    one. Whether that reproduces against PSG is a question a pooled table cannot be asked.

    Subjects split into terciles by SCORED night length.
    """)
    let sortedRows = shipped.sorted { $0.subject.scoredMinutes < $1.subject.scoredMinutes }
    let third = max(1, sortedRows.count / 3)
    let strata: [(String, [Scored])] = [
        ("short", Array(sortedRows.prefix(third))),
        ("mid", Array(sortedRows.dropFirst(third).dropLast(sortedRows.count - 2 * third))),
        ("long", Array(sortedRows.suffix(sortedRows.count - 2 * third))),
    ]
    print("    stratum   n   night min      kappa   REM% pred  REM% truth   deep% pred deep% truth  wake% pred wake% truth")
    for (name, rows) in strata where !rows.isEmpty {
        let p = pooledPct(rows) { $0.pred }, t = pooledPct(rows) { $0.truth }
        var c = Confusion()
        for r in rows { for i in 0..<r.truth.count { c.add(ref: r.truth[i], pred: r.pred[i]) } }
        let mins = rows.map { $0.subject.scoredMinutes }
        print("    \(name.padding(toLength: 9, withPad: " ", startingAt: 0))\(rows.count)  \(f(median(mins), 8, 1))  \(f(c.kappa, 9, 3))  \(f(p["rem"]!, 9, 2)) \(f(t["rem"]!, 10, 2))  \(f(p["deep"]!, 10, 2)) \(f(t["deep"]!, 10, 2))  \(f(p["wake"]!, 10, 2)) \(f(t["wake"]!, 10, 2))")
    }
    // The coupling itself, per subject: REM as a percentage of SLEEP (not of the window), against the
    // length of the scored night.
    func remPctOfSleep(_ labels: [String]) -> Double? {
        let sleep = labels.filter { $0 != "wake" }.count
        guard sleep > 0 else { return nil }
        return Double(labels.filter { $0 == "rem" }.count) / Double(sleep) * 100
    }
    var lens: [Double] = [], remPred: [Double] = [], remTruth: [Double] = []
    for r in shipped {
        guard let rp = remPctOfSleep(r.pred), let rt = remPctOfSleep(r.truth) else { continue }
        lens.append(r.subject.scoredMinutes); remPred.append(rp); remTruth.append(rt)
    }
    let cp = pearson(lens, remPred), ct = pearson(lens, remTruth)
    print("""

    corr(scored night length, REM % of SLEEP), n = \(cp.n)
      predicted   Pearson \(f(cp.r, 7, 3))   Spearman \(f(spearman(lens, remPred), 7, 3))
      PSG truth   Pearson \(f(ct.r, 7, 3))   Spearman \(f(spearman(lens, remTruth), 7, 3))
    A coupling the truth also carries is physiology; one only the prediction carries is an artefact.
    """)
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// The REM question
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("rem") {
    print("""

    ================================================================================
    5. IS REM DETECTION PHYSIOLOGY, OR IS IT THE CLOCK?
    ================================================================================
    Three models fit on the same epochs, leave-one-SUBJECT-out, scored only on the held-out subject.
    Clock features are the time-of-night fraction and its square; physiology features are the per-night
    z-scored heart rate, HR-variability and movement plus the HR-flatness percentile — the same normalised
    quantities the recipe's own emissions are built from. Decision threshold tuned on the training folds.
    """)
    var rows: [AblationRow] = []
    for s in subjects {
        let (feats, _) = V2Recipe.stageEpochsDetailed(start: s.start, end: s.end, grav: s.grav,
                                                      hr: s.hr, rr: [], resp: [])
        // Per-night normalisation, matching `stageEpochs`.
        func zfun(_ vals: [Double?]) -> (Double?) -> Double {
            let present = vals.compactMap { $0 }
            if present.isEmpty { return { _ in 0.0 } }
            let m = present.reduce(0, +) / Double(present.count)
            let sd0 = (present.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(present.count)).squareRoot()
            let sdv = sd0 == 0 ? 1.0 : sd0
            return { v in v == nil ? 0.0 : (v! - m) / sdv }
        }
        let zhr = zfun(feats.map { $0.hr }), zhv = zfun(feats.map { $0.hrVar })
        let zmv = zfun(feats.map { Optional($0.moveFrac) })
        let fsorted = feats.compactMap { $0.hrFlat11 }.sorted()
        func fpct(_ v: Double?) -> Double {
            guard let v = v, !fsorted.isEmpty else { return 0.5 }
            var lo = 0, hi = fsorted.count
            while lo < hi { let mid = (lo + hi) / 2; if fsorted[mid] <= v { lo = mid + 1 } else { hi = mid } }
            return Double(lo) / Double(fsorted.count)
        }
        for e in feats {
            let idx = (e.start - s.start) / 30
            guard idx >= 0, idx < s.truth.count, let tv = s.truth[idx] else { continue }
            rows.append(AblationRow(
                subject: s.id, isRem: tv == "rem",
                clock: [e.clock, e.clock * e.clock],
                physiology: [zhr(e.hr), zhv(e.hrVar), zmv(e.moveFrac), fpct(e.hrFlat11)]))
        }
    }
    print("    epochs in the comparison: \(rows.count)   REM prevalence \(f(Double(rows.filter { $0.isRem }.count) / Double(max(1, rows.count)) * 100, 5, 1)) %\n")
    let res = Ablation.run(rows)
    print("    model               pooled F1   pooled P   pooled R   mean per-subject F1")
    for r in res {
        print("      \(r.model.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0))\(f(r.pooledF1, 8, 3))  \(f(r.pooledPrecision, 9, 3))  \(f(r.pooledRecall, 9, 3))   \(f(r.meanSubjectF1, 12, 3))")
    }
    if let clock = res.first(where: { $0.model == .clock }),
       let phys = res.first(where: { $0.model == .physiology }),
       let both = res.first(where: { $0.model == .both }) {
        let subs = clock.subjectF1.keys.sorted()
        let dPhys = subs.compactMap { s -> Double? in
            guard let c = clock.subjectF1[s], let p = phys.subjectF1[s] else { return nil }
            return p - c
        }
        let dBoth = subs.compactMap { s -> Double? in
            guard let c = clock.subjectF1[s], let b = both.subjectF1[s] else { return nil }
            return b - c
        }
        print("""

            what physiology adds over the clock, per subject
              physiology-only − clock-only   mean \(f(mean(dPhys), 7, 3))   positive in \(dPhys.filter { $0 > 0 }.count)/\(dPhys.count) subjects
              both − clock-only              mean \(f(mean(dBoth), 7, 3))   positive in \(dBoth.filter { $0 > 0 }.count)/\(dBoth.count) subjects
              pooled: physiology-only − clock-only \(f(phys.pooledF1 - clock.pooledF1, 7, 3)),  both − clock-only \(f(both.pooledF1 - clock.pooledF1, 7, 3))

            For reference, the SHIPPED recipe's own REM F1 on these epochs is \(f(sh.conf.prf("rem").f1, 6, 3)) — it fits
            nothing, so it is not comparable to a fitted model's held-out score and is printed only for scale.
        """)
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Variants
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

if want("variants") || a.section == "candidates" {
    print("""

    ================================================================================
    6. RECIPE VARIANTS AGAINST PSG
    ================================================================================
    Every row is the shipped recipe with ONE named change. Deltas are against the incumbent row.
    `wake bias` and `deep bias` are predicted minus truth in percentage points — the #437 guard, which
    kappa does not carry.
    """)
    var csvLines = [(["variant", "epochs", "kappa", "accuracy"]
        + stageOrder.flatMap { ["\($0)_precision", "\($0)_recall", "\($0)_f1", "\($0)_pct", "\($0)_bias_pp"] }
        + ["median_rem_latency_min", "rem_latency_mae_min"]).joined(separator: ",")]
    var base: (kappa: Double, remF1: Double, wakeSens: Double)?
    // Wake SENSITIVITY is in the table beside kappa because it is the quantity #987 was landed on against
    // the strap's band state (16.0 % → 17.6 %). Printing it here is what makes that claim checkable against
    // truth rather than merely restated.
    print("    variant                          kappa     Δκ   REM F1  wakeSens   wake%  bias   deep%  bias    REM%  bias   latMAE")
    var variantRows: [(name: String, rows: [Scored])] = []
    for v in (a.section == "candidates" ? Variants.candidates : Variants.all) {
        let rows = v.name.hasPrefix("incumbent")
            ? shipped
            : subjects.map { score($0, using: stageVariant(v.config)) }
        variantRows.append((v.name, rows))
        let s = summarise(rows)
        let p = pooledPct(rows) { $0.pred }, t = pooledPct(rows) { $0.truth }
        let latMae = mae(zip(s.latencyPairsPred, s.latencyPairsTruth).map { $0 - $1 })
        let wakeSens = s.conf.prf("wake").recall * 100
        if base == nil { base = (s.kappa, s.conf.prf("rem").f1, wakeSens) }
        let b = base!
        print("    \(v.name.padding(toLength: 32, withPad: " ", startingAt: 0))\(f(s.kappa, 6, 3)) \(f(s.kappa - b.kappa, 6, 3))   \(f(s.conf.prf("rem").f1, 6, 3))  \(f(wakeSens, 6, 2))\(f(wakeSens - b.wakeSens, 6, 2))  \(f(p["wake"]!, 6, 2))\(f(p["wake"]! - t["wake"]!, 6, 2))  \(f(p["deep"]!, 6, 2))\(f(p["deep"]! - t["deep"]!, 6, 2))  \(f(p["rem"]!, 6, 2))\(f(p["rem"]! - t["rem"]!, 6, 2))  \(f(latMae, 6, 1))")
        var row = [v.name, "\(s.conf.total)", "\(s.kappa)", "\(s.accuracy)"]
        for st in stageOrder {
            let m = s.conf.prf(st)
            row += ["\(m.precision)", "\(m.recall)", "\(m.f1)", "\(p[st]!)", "\(p[st]! - t[st]!)"]
        }
        row += ["\(median(s.latencyPred))", "\(latMae)"]
        csvLines.append(row.joined(separator: ","))
    }
    // Plausibility against bands drawn from the PSG hypnograms themselves. The truth row is inside its own
    // bands about 80 % of the time by construction (p10..p90), which is the yardstick for the other rows.
    let truthMetrics = shipped.map { NightMetrics.of($0.truth) }
    let psgBands = PlausibilityBands.derive(from: truthMetrics, source: "PSG p10..p90 over \(truthMetrics.filter { $0.hasSleep }.count) subjects (sleep-accel)")
    print("\n    PLAUSIBILITY against \(psgBands.source) — shape, not accuracy")
    print("    row                              inside bands  transitions/h  short-bout share  REM period min")
    func plausibilityRow(_ name: String, _ labels: [[String]]) {
        let ms = labels.map { NightMetrics.of($0) }.filter { $0.hasSleep }
        let inside = ms.map { psgBands.score($0) }.reduce((0, 0)) { ($0.0 + $1.inside, $0.1 + $1.judged) }
        let spacing = ms.compactMap { $0.remPeriodMin }
        print("    \(name.padding(toLength: 32, withPad: " ", startingAt: 0)) \(f(Double(inside.0) / Double(max(1, inside.1)) * 100, 9, 1))%  \(f(median(ms.map { $0.transitionsPerHour }), 12, 1)) \(f(median(ms.map { $0.shortBoutShare }) * 100, 15, 0))% \(f(median(spacing), 14, 0))")
    }
    plausibilityRow("PSG truth", shipped.map { $0.truth })
    for vr in variantRows { plausibilityRow(vr.name, vr.rows.map { $0.pred }) }
    if let path = a.bandsOut {
        try? psgBands.encoded().write(to: URL(fileURLWithPath: path))
        print("    PSG plausibility bands written to \(path)")
    }
    print("""

    A component is an improvement here only if it raises kappa AND does not blow out a stage fraction.
    That conjunction is the lesson of #348 → #437: kappa alone certified a build that mis-called a
    healthy night's wake fraction by 17 percentage points.
    """)
    if let path = a.csv {
        try? csvLines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("    per-variant CSV written to \(path)")
    }
}

if want("priors") {
    print("""

    ================================================================================
    7. BASE PRIORS, SUBJECT BY SUBJECT
    ================================================================================
    The pooled table above can be carried by a few long nights. Here every subject counts once: their own
    kappa, and how far each stage's share of THEIR night is from their own PSG. The deep prior moved 0.18 →
    0.15 on this section's evidence; the "before" row is that change undone, and #348-A adds the awake half
    the recipe does not take. `better` counts subjects whose value improved against the incumbent (kappa up,
    |bias| down); a tie counts as neither.
    """)
    func perSubject(_ rows: [Scored]) -> [(kappa: Double, bias: [String: Double])] {
        rows.map { r in
            let bias = stageBias(ref: r.truth, pred: r.pred)
            return (confusion(ref: r.truth, pred: r.pred).kappa, bias)
        }
    }
    let base = perSubject(shipped)
    print("    variant                     mean κ  better κ   mean|bias| wake  deep   REM  light   better |bias| wake deep  REM light")
    for v in [Variants.incumbent, Variants.deepPriorBefore, Variants.p348Priors] {
        let rows = v.name.hasPrefix("incumbent") ? shipped : subjects.map { score($0, using: stageVariant(v.config)) }
        let ps = perSubject(rows)
        let n = ps.count
        let kBetter = zip(ps, base).filter { $0.0.kappa > $0.1.kappa }.count
        func meanAbs(_ st: String) -> Double { mean(ps.map { abs($0.bias[st] ?? 0) }) }
        func better(_ st: String) -> Int { zip(ps, base).filter { abs($0.0.bias[st] ?? 0) < abs($0.1.bias[st] ?? 0) }.count }
        print("    \(v.name.padding(toLength: 26, withPad: " ", startingAt: 0))\(f(mean(ps.map { $0.kappa }), 7, 3))   \(kBetter)/\(n)     "
              + "\(f(meanAbs("wake"), 5, 2)) \(f(meanAbs("deep"), 5, 2)) \(f(meanAbs("rem"), 5, 2)) \(f(meanAbs("light"), 5, 2))      "
              + "\(better("wake"))/\(n) \(better("deep"))/\(n) \(better("rem"))/\(n) \(better("light"))/\(n)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// Per-subject comparisons: sign test, graded dropout, prior ablation. Named sections only — they are not part
// of `all` because each re-stages every subject several times.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

/// Stage every subject with `cfg`, concurrently, and score against the PSG. The recipe port is pure, so the
/// subjects are independent and the result order is the input order.
func scoreAll(_ subs: [PSGSubject], _ cfg: RecipeConfig) -> [Scored] {
    var out = [Scored?](repeating: nil, count: subs.count)
    out.withUnsafeMutableBufferPointer { buf in
        let b = buf
        DispatchQueue.concurrentPerform(iterations: subs.count) { i in
            b[i] = score(subs[i], using: stageVariant(cfg))
        }
    }
    return out.map { $0! }
}

/// Mean of the per-subject kappas, leaving out the subjects whose night carries a single class.
func meanSubjectKappa(_ rows: [Scored]) -> Double {
    mean(rows.map { confusion(ref: $0.truth, pred: $0.pred).kappa }.filter { !$0.isNaN })
}

func signedF(_ v: Double, _ w: Int = 7, _ p: Int = 3) -> String {
    v.isNaN ? String(repeating: " ", count: max(0, w - 3)) + "n/a" : String(format: "%+\(w).\(p)f", v)
}

if a.section == "signtest" {
    let cand = Variants.c5bOnsetAnchoredStats
    print("""

    ================================================================================
    SIGN TEST. \(cand.name.uppercased()) AGAINST THE INCUMBENT, SUBJECT BY SUBJECT, ON PSG
    ================================================================================
    Same subjects, same scored epochs, same PSG. Each subject's four-class kappa against its own hypnogram is
    computed for the shipped stager and for the candidate; the candidate WINS a subject when its kappa is higher.
    A kappa difference below \(PairedComparison.tieEpsilon) is a tie (an identical hypnogram). The test is the exact two-sided sign
    test over subjects (ties dropped); the interval is a percentile bootstrap over subjects (4 000 resamples,
    seeded). Minutes are per night; "error" is |minutes in the stage - the PSG's minutes in that stage|.
    """)
    let candRows = scoreAll(subjects, cand.config)
    let r = PairedComparison.compare(truth: shipped.map { $0.truth }, base: shipped.map { $0.pred },
                                     cand: candRows.map { $0.pred })
    print("    subject   scored min   kappa inc   kappa cand   change   | minutes change (cand - inc):  wake  light   deep    REM")
    for (i, row) in shipped.enumerated() {
        func d(_ st: String) -> String {
            let n = { (rows: [Scored]) in Double(rows[i].pred.filter { $0 == st }.count) * 0.5 }
            return String(format: "%+6.1f", n(candRows) - n(shipped))
        }
        print("    \(row.subject.id.padding(toLength: 9, withPad: " ", startingAt: 0)) \(f(row.subject.scoredMinutes, 10, 1))   \(f(r.kappaBase[i], 9, 3))   \(f(r.kappaCand[i], 10, 3))   \(signedF(r.kappaCand[i] - r.kappaBase[i], 6, 3))   |                              \(d("wake")) \(d("light")) \(d("deep")) \(d("rem"))")
    }
    let pooledBase = summarise(shipped).kappa, pooledCand = summarise(candRows).kappa
    print("""

    subjects                 \(r.subjects)   (kappa defined for \(r.wins + r.losses + r.ties))
    candidate wins / losses / ties   \(r.wins) / \(r.losses) / \(r.ties)
    exact two-sided sign test   p = \(f(r.signP, 6, 3))
    mean per-subject change in kappa   \(signedF(r.meanDelta, 7, 4))   95 % bootstrap interval [\(signedF(r.ciLow, 7, 4)), \(signedF(r.ciHigh, 7, 4))]
    pooled kappa   incumbent \(f(pooledBase, 6, 3))   candidate \(f(pooledCand, 6, 3))   (\(signedF(pooledCand - pooledBase, 6, 3)))

    MINUTES PER STAGE, per night (mean over subjects)
    stage      shift (cand - inc)   worst |shift|   error inc   error cand   subjects closer / farther to PSG
    """)
    for st in stageOrder {
        let m = r.stages[st]!
        print("      \(st.padding(toLength: 8, withPad: " ", startingAt: 0)) \(signedF(m.meanShift, 14, 2))   \(f(m.worstShift, 12, 1))   \(f(m.errorBase, 9, 1))   \(f(m.errorCand, 10, 1))   \(String(format: "%2d", m.closer)) / \(String(format: "%-2d", m.farther))")
    }
    print("""

    With \(r.wins + r.losses) subjects that are not ties, the two-sided sign test needs at least \(Separation.decisiveSplit(n: r.wins + r.losses).map(String.init) ?? "more than all of them") of them
    on one side to reach p < 0.05 (a tie is not a vote). "Not significant" means the cohort cannot tell the two
    apart, not that they are equal.
    The comparison is on a laboratory cohort of Apple Watch signals, with no R-R: the recipe's respiration term
    is silent here, and what C5b changes (the window the statistics are taken over) is exercised on 8-hour
    nights that are already well framed.
    """)
}

if a.section == "dropout" {
    let variants: [(name: String, cfg: RecipeConfig)] = [
        ("incumbent", .shipped), ("C1", Variants.c1MissingGravityNeutral.config), ("C5b", Variants.c5bOnsetAnchoredStats.config),
    ]
    print("""

    ================================================================================
    SYNTHETIC DROPOUT. C1 AND C5b AGAINST PSG UNDER GRADED DATA LOSS
    ================================================================================
    Each scenario removes the same samples for every recipe (seeded per subject and scenario), then scores the
    staged night against the PSG. The incumbent runs through the recipe port with the shipped config: the port is
    pinned label-for-label to `SleepStagerV2` by the port validation, and the clean run below re-checks it on this
    dataset. Gravity can only be lost in holes (a contiguous gap, or 2-minute bursts), because dropping single
    seconds leaves every epoch with plenty. kappa is the mean of the per-subject kappas against the PSG.
    """)
    let cleanRows = variants.map { scoreAll(subjects, $0.cfg) }
    let portMatches = zip(cleanRows[0], shipped).allSatisfy { $0.0.pred == $0.1.pred }
    print("    clean run: the port at the shipped config reproduces the shipped stager's labels on every subject: \(portMatches ? "yes" : "NO — numbers below are not about the shipped recipe")")
    let cleanKappa = cleanRows.map { meanSubjectKappa($0) }
    print("    clean            kappa   incumbent \(f(cleanKappa[0], 6, 3))   C1 \(f(cleanKappa[1], 6, 3))   C5b \(f(cleanKappa[2], 6, 3))")

    print("""

    kappa under damage (mean per subject) and what the damage cost each recipe (clean kappa - damaged kappa)
    scenario                              removed      incumbent   cost     C1   cost      C5b   cost
    """)
    struct Row { let name: String; let removed: String; let kappa: [Double]; let paired: [PairedResult] }
    var table: [Row] = []
    for sc in DropoutScenario.all {
        let damaged = subjects.map { sc.apply(to: $0) }
        let rows = variants.map { scoreAll(damaged, $0.cfg) }
        let kappas = rows.map { meanSubjectKappa($0) }
        let gravGone = 1 - Double(damaged.reduce(0) { $0 + $1.grav.count }) / Double(max(1, subjects.reduce(0) { $0 + $1.grav.count }))
        let hrGone = 1 - Double(damaged.reduce(0) { $0 + $1.hr.count }) / Double(max(1, subjects.reduce(0) { $0 + $1.hr.count }))
        let removed = [gravGone > 1e-9 ? "grav \(f(gravGone * 100, 4, 1))%" : nil, hrGone > 1e-9 ? "HR \(f(hrGone * 100, 4, 1))%" : nil]
            .compactMap { $0 }.joined(separator: " ")
        let truth = rows[0].map { $0.truth }
        let paired = (1..<variants.count).map {
            PairedComparison.compare(truth: truth, base: rows[0].map { $0.pred }, cand: rows[$0].map { $0.pred })
        }
        table.append(Row(name: sc.name, removed: removed, kappa: kappas, paired: paired))
        print("    \(sc.name.padding(toLength: 36, withPad: " ", startingAt: 0)) \(removed.padding(toLength: 12, withPad: " ", startingAt: 0)) \(f(kappas[0], 8, 3)) \(f(cleanKappa[0] - kappas[0], 6, 3))  \(f(kappas[1], 6, 3)) \(f(cleanKappa[1] - kappas[1], 6, 3))   \(f(kappas[2], 6, 3)) \(f(cleanKappa[2] - kappas[2], 6, 3))")
    }

    print("""

    PAIRED AGAINST THE INCUMBENT UNDER THE SAME DAMAGE (change in per-subject kappa; wins / losses / ties over subjects; exact sign test)
    scenario                              | C1:  change   [95 % interval]      W / L / T    p     | C5b: change   [95 % interval]      W / L / T    p
    """)
    func pairedCell(_ p: PairedResult) -> String {
        "\(signedF(p.meanDelta, 7, 4)) [\(signedF(p.ciLow, 7, 4)), \(signedF(p.ciHigh, 7, 4))]  \(String(format: "%2d", p.wins)) /\(String(format: "%2d", p.losses)) /\(String(format: "%2d", p.ties))  \(f(p.signP, 6, 3))"
    }
    // The clean row first: the baseline the damaged rows are read against.
    let cleanPaired = (1..<variants.count).map {
        PairedComparison.compare(truth: cleanRows[0].map { $0.truth }, base: cleanRows[0].map { $0.pred }, cand: cleanRows[$0].map { $0.pred })
    }
    print("    \("clean (no damage)".padding(toLength: 37, withPad: " ", startingAt: 0))| \(pairedCell(cleanPaired[0]))   | \(pairedCell(cleanPaired[1]))")
    for row in table {
        print("    \(row.name.padding(toLength: 37, withPad: " ", startingAt: 0))| \(pairedCell(row.paired[0]))   | \(pairedCell(row.paired[1]))")
    }
    print("""

    How to read it. `cost` is how much kappa each recipe loses against the PSG when the damage lands; the paired
    block asks whether a candidate beats the incumbent subject by subject under that same damage. C1 can only
    matter where gravity is PARTLY missing (a hole or bursts), and is a no-op on the heart-rate scenarios by
    construction; C5b changes where the statistics are taken, so it can matter under either. A candidate that
    loses less kappa than the incumbent under damage is more robust; it is not thereby more accurate on a clean
    night, which the first line and the sign-test section report. The damage is synthetic: it says how the
    recipes behave when samples vanish in these patterns, not that a strap loses data in them.
    """)
}

if a.section == "priorsoff" {
    let ablations = Variants.ablations
    print("""

    ================================================================================
    PRIOR ABLATION. HOW MUCH OF THE RESULT IS THE SIGNALS, HOW MUCH IS THE CLOCK?
    ================================================================================
    Rows remove one thing from the recipe and score the result against the PSG. `cycle prior` is the deep-early /
    REM-late position-in-the-night term, `REM guard` is the #930 latency penalty. `signals off` is a CONTROL: every
    per-epoch measurement term at zero, so only the priors, the clock and the transition matrix remain. The last row
    removes both priors from that, which leaves only the base rates: it should call everything light (kappa near 0).
    Nothing here is a candidate. Subject kappa is the mean of per-subject kappas; the paired columns difference
    each row against the incumbent subject by subject.
    """)
    var rows: [[Scored]] = []
    for v in ablations { rows.append(v.name.hasPrefix("incumbent (shipped)") && v.config == .shipped ? shipped : scoreAll(subjects, v.config)) }
    let truth = shipped.map { $0.truth }
    print("    row                                                    pooled k  subj k   REM F1  deep F1  wake rec   wake bias  deep bias  REM bias   vs incumbent: change   W / L / T     p")
    let base = rows[0].map { $0.pred }
    for (i, v) in ablations.enumerated() {
        let s = summarise(rows[i])
        let p = pooledPct(rows[i]) { $0.pred }, t = pooledPct(rows[i]) { $0.truth }
        let pr = PairedComparison.compare(truth: truth, base: base, cand: rows[i].map { $0.pred })
        let cmp = i == 0 ? "         (baseline)" : "\(signedF(pr.meanDelta, 8, 3))   \(String(format: "%2d", pr.wins)) /\(String(format: "%2d", pr.losses)) /\(String(format: "%2d", pr.ties))   \(f(pr.signP, 6, 3))"
        print("    \(v.name.padding(toLength: 54, withPad: " ", startingAt: 0)) \(f(s.kappa, 8, 3)) \(f(meanSubjectKappa(rows[i]), 7, 3)) \(f(s.conf.prf("rem").f1, 7, 3)) \(f(s.conf.prf("deep").f1, 8, 3)) \(f(s.conf.prf("wake").recall * 100, 8, 1)) \(signedF(p["wake"]! - t["wake"]!, 10, 2)) \(signedF(p["deep"]! - t["deep"]!, 10, 2)) \(signedF(p["rem"]! - t["rem"]!, 9, 2))   \(cmp)")
    }
    let k = summarise(rows[0]).kappa
    print("""

    Share of the incumbent's pooled kappa (\(f(k, 5, 3))) that survives each removal:
    """)
    for (i, v) in ablations.enumerated() where i > 0 {
        let kk = summarise(rows[i]).kappa
        print("      \(v.name.padding(toLength: 54, withPad: " ", startingAt: 0)) \(f(kk / k * 100, 6, 1)) %")
    }
    print("""

    How to read it. The share that survives with `signals off` is the part of the agreement that needs no
    measurement at all (base rates, the clock, the sticky transitions); the cycle-prior and guard rows say which
    of the two clock terms carries it. A recipe whose kappa barely moves when the signals are removed is mostly
    priors. The ablation measures dependence, not correctness: a term whose removal costs nothing is not
    thereby wrong, and one whose removal costs a lot is not thereby right.
    """)
}

print("")
