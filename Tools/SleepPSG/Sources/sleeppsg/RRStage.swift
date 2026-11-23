import Foundation
import SleepRecipe
import StrandAnalytics
import WhoopProtocol

// RRStage — do ln(RMSSD) and ln(LF/HF) tell deep from REM sleep on a polysomnogram that carries real
// beat-to-beat data? This is the question that has to be answered BEFORE candidate C3 (weights on those two
// features) is worth re-running anywhere: on the wearer's own nights the only references are the strap's
// sleep/wake band state and the recipe's own output, and `sleep-accel` has no R-R at all.
//
// DATA. MIT-BIH Polysomnographic Database (Ichimaru & Moody 1999; PhysioNet, ODC-By 1.0): 18 records of
// 16 patients (slp01a/b and slp02a/b are two segments of one patient each), a beat-annotated ECG and a
// human-scored 30 s hypnogram. `scripts/slpdb_export.py` turns the WFDB files into the CSVs read here.
//
// ESTIMATORS. The features are NOT recomputed here. The beats go through `V2Recipe.stageEpochsDetailed` with
// the C3 weights switched on, so `lnRmssd` and `lnLfHf` are exactly what the recipe would feed its emission:
// a centred 5-minute window, `HRVAnalyzer.cleanRRGapAware`, `rmssdGapAware`, `HRVFreqDomain.freqDomain`.
// The recipe's other cardiac inputs (mean HR, HR spread over the same window, respiration regularity) come
// out of the same call and are measured the same way, so "does RMSSD separate the stages" can be put next to
// "does heart rate already do it". HR here is DERIVED from the beats (60000 / interval), not recorded.
//
// WHAT THIS CANNOT SHOW (the report repeats it): the cohort is 16 men aged 32-56 recorded for suspected sleep-
// disordered breathing, so deep sleep is 6 % and REM 7 % of scored epochs and apnoea-driven cyclic heart-rate
// variation sits on top of everything; the signal is a chest ECG, cleaner than the strap's optical R-R; and
// the numbers say how well a feature separates two stages, not how much a staging recipe would gain from it.

/// One 30 s epoch of one record, with the recipe's cardiac features read through the 5-minute window centred
/// on it.
struct RRStageEpoch {
    let subject: String
    let record: String
    /// Minutes since the record's first annotated epoch — the time axis the detrending variant removes.
    let minutes: Double
    /// wake / light / deep / rem, or nil for an epoch the database leaves unscored (movement time, etc.).
    let stage: String?
    /// How many of the 11 epochs the 5-minute window spans carry an annotated respiratory event (apnoea or
    /// hypopnea): 0 means a window free of them.
    let eventEpochs: Int
    let lnRmssd: Double?
    let lnLfHf: Double?
    let hr: Double?
    let hrVar: Double?
    let respReg: Double?

    var eventFree: Bool { eventEpochs == 0 }
}

/// One record as `scripts/slpdb_export.py` wrote it.
struct SlpdbRecord {
    struct Epoch { let stage: String?; let respiratoryEvent: Bool }

    let id: String
    let beats: [(t: Double, symbol: String)]
    let epochs: [Int: Epoch]            // keyed by the epoch's start second, a multiple of 30

    /// The patient. `slp01a`/`slp01b` and `slp02a`/`slp02b` are segments of one patient; every other record id
    /// (including `slp67x`, whose `x` is part of its name) is its own.
    var subject: String { id.hasSuffix("a") || id.hasSuffix("b") ? String(id.dropLast()) : id }

    static let respiratoryTokens: Set<String> = ["OA", "X", "CA", "CAA", "H", "HA"]

    /// R&K stage code → NOOP's four classes, the same collapse `SleepAccel.stageForCode` applies.
    static func stage(forToken t: String) -> String? {
        switch t {
        case "W": return "wake"
        case "1", "2": return "light"
        case "3", "4": return "deep"
        case "R": return "rem"
        default: return nil             // MT, M, anything else: unscored, dropped from every statistic
        }
    }

    static func load(dir: String, id: String) -> SlpdbRecord? {
        let fm = FileManager.default
        guard let beatData = fm.contents(atPath: (dir as NSString).appendingPathComponent("\(id).beats.csv")),
              let stageData = fm.contents(atPath: (dir as NSString).appendingPathComponent("\(id).stages.csv")),
              let beatText = String(data: beatData, encoding: .utf8),
              let stageText = String(data: stageData, encoding: .utf8) else { return nil }

        var beats: [(t: Double, symbol: String)] = []
        for line in beatText.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).dropFirst() {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ",", maxSplits: 1)
            guard parts.count == 2, let t = Double(parts[0]) else { continue }
            beats.append((t, String(parts[1])))
        }

        var epochs: [Int: Epoch] = [:]
        for line in stageText.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).dropFirst() {
            // epoch_start_s,stage,events — the events field may be quoted and may carry a comma of its own.
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ",", maxSplits: 2,
                                                                         omittingEmptySubsequences: false)
            guard parts.count >= 2, let t = Int(parts[0]) else { continue }
            let events = parts.count > 2
                ? parts[2].replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: ",", with: " ")
                : ""
            let respiratory = events.split(separator: " ").contains { respiratoryTokens.contains(String($0)) }
            epochs[t] = Epoch(stage: stage(forToken: String(parts[1])), respiratoryEvent: respiratory)
        }
        guard !beats.isEmpty, !epochs.isEmpty else { return nil }
        return SlpdbRecord(id: id, beats: beats, epochs: epochs)
    }

    /// Record ids in a directory of exports, from the `*.stages.csv` files present.
    static func ids(in dir: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.compactMap { $0.hasSuffix(".stages.csv") ? String($0.dropLast(".stages.csv".count)) : nil }.sorted()
    }

    /// The recipe's inputs for this record: every interval between consecutive annotated beats, as a strap
    /// would report them (the app's own range filter and ectopic rejection do the cleaning — beats are not
    /// pre-screened by their annotated type), plus a 1 Hz-ish heart-rate series derived from the same beats
    /// so the recipe has epochs to featurise.
    func recipeStreams() -> (rr: [RRInterval], hr: [HRSample]) {
        var rr: [RRInterval] = [], hr: [HRSample] = []
        rr.reserveCapacity(beats.count); hr.reserveCapacity(beats.count)
        for i in 1..<max(1, beats.count) {
            let ms = (beats[i].t - beats[i - 1].t) * 1000
            guard ms > 0 else { continue }
            let ts = SleepAccel.timeBase + Int(beats[i].t.rounded(.down))
            rr.append(RRInterval(ts: ts, rrMs: Int(ms.rounded())))
            if ms >= 300 && ms <= 2000 { hr.append(HRSample(ts: ts, bpm: Int((60_000 / ms).rounded()))) }
        }
        return (rr, hr)
    }

    /// Per-epoch features through the recipe's own extraction (C3 weights on, so the R-R terms are computed).
    func features() -> [RRStageEpoch] {
        guard let first = epochs.keys.min(), let last = epochs.keys.max() else { return [] }
        let (rr, hr) = recipeStreams()
        var cfg = RecipeConfig.shipped
        cfg.rmssdWeight = 0.6; cfg.lfhfWeight = 0.3       // the weights are irrelevant here; non-zero turns the terms on
        let detail = V2Recipe.stageEpochsDetailed(start: SleepAccel.timeBase + first,
                                                   end: SleepAccel.timeBase + last + 30,
                                                   grav: [], hr: hr, rr: rr, resp: [], cfg: cfg)
        return detail.epochs.compactMap { e in
            let rel = e.start - SleepAccel.timeBase
            guard let ep = epochs[rel] else { return nil }
            // The window [e - 150 s, e + 180 s) spans the 11 epochs starting at e - 150 ... e + 150.
            let events = (-5...5).filter { epochs[rel + $0 * 30]?.respiratoryEvent ?? false }.count
            return RRStageEpoch(subject: subject, record: id, minutes: Double(rel - first) / 60,
                                stage: ep.stage, eventEpochs: events,
                                lnRmssd: e.lnRmssd, lnLfHf: e.lnLfHf, hr: e.hr, hrVar: e.hrVar, respReg: e.respReg)
        }
    }
}

// MARK: - Analysis

/// A cardiac feature, with the direction the recipe's emission assumes for each stage as the feature rises.
enum SepFeature: CaseIterable {
    case lnRmssd, lnLfHf, hr, hrVar, respReg

    var label: String {
        switch self {
        case .lnRmssd: return "ln RMSSD"
        case .lnLfHf: return "ln LF/HF"
        case .hr: return "heart rate"
        case .hrVar: return "HR spread 5 min"
        case .respReg: return "resp. regularity"
        }
    }

    func value(_ e: RRStageEpoch) -> Double? {
        switch self {
        case .lnRmssd: return e.lnRmssd
        case .lnLfHf: return e.lnLfHf
        case .hr: return e.hr
        case .hrVar: return e.hrVar
        case .respReg: return e.respReg
        }
    }

    /// The push the recipe's emission gives `stage` when this feature rises (light and wake get none). Only
    /// the sign and the ordering matter: they say which stage the recipe EXPECTS to read higher. The values are
    /// the shipped coefficients (`deepZhv`, `remZhr`, `respWeight`) and the a-priori C3 weights.
    func assumedPush(_ stage: String) -> Double {
        switch (self, stage) {
        case (.lnRmssd, "deep"): return 0.6
        case (.lnRmssd, "rem"): return -0.6
        case (.lnLfHf, "deep"): return -0.3
        case (.lnLfHf, "rem"): return 0.3
        case (.hr, "rem"): return 0.4
        case (.hrVar, "deep"): return -1.1
        case (.hrVar, "rem"): return 0.6
        case (.respReg, "deep"): return 0.6
        case (.respReg, "rem"): return -0.6
        default: return 0
        }
    }

    /// The stage the recipe expects to read higher, or nil when it assumes nothing about the pair.
    func expectedHigher(_ a: String, _ b: String) -> String? {
        let pa = assumedPush(a), pb = assumedPush(b)
        if pa == pb { return nil }
        return pa > pb ? a : b
    }
}

/// How the epochs are filtered or adjusted before the contrast is measured.
enum SepVariant: CaseIterable {
    case all, eventFree, timeDetrended, hrAdjusted, recipeAdjusted, eventAdjusted

    var label: String {
        switch self {
        case .all: return "all windows"
        case .eventFree: return "windows with no annotated apnoea/hypopnea"
        case .timeDetrended: return "time-detrended (linear in minutes, per record, sleep epochs)"
        case .hrAdjusted: return "HR-adjusted (linear in the epoch's own HR, per patient, sleep epochs)"
        case .recipeAdjusted: return "adjusted for what the recipe already reads (HR, HR spread, resp. regularity, jointly, per patient)"
        case .eventAdjusted: return "adjusted for annotated apnoea/hypopnea (epochs with an event in the window, per patient)"
        }
    }
}

struct SubjectContrast {
    let subject: String
    let nHigh: Int, nLow: Int
    let auc: Double          // P(feature of the expected-higher stage > the other's)
    let d: Double            // Cohen's d, same orientation
}

enum RRStageAnalysis {
    static let contrasts: [(String, String)] = [("deep", "rem"), ("deep", "light"), ("rem", "light")]
    /// A patient needs at least this many featurised epochs (10 minutes) of BOTH stages to enter a contrast.
    static let minEpochs = 20

    /// `(stage, value)` pairs for one patient's epochs under a variant. Adjusted variants are fitted on the
    /// patient's sleep epochs (light, deep, REM) with no reference to the stage label.
    static func series(_ feature: SepFeature, _ variant: SepVariant,
                       _ epochs: [RRStageEpoch]) -> [(stage: String, value: Double)] {
        let sleep = epochs.filter { $0.stage != nil && $0.stage != "wake" && feature.value($0) != nil }
        switch variant {
        case .all:
            return sleep.map { ($0.stage!, feature.value($0)!) }
        case .eventFree:
            return sleep.filter { $0.eventFree }.map { ($0.stage!, feature.value($0)!) }
        case .timeDetrended:
            var out: [(String, Double)] = []
            for rec in Set(sleep.map { $0.record }) {
                let r = sleep.filter { $0.record == rec }
                let res = Separation.residuals(y: r.map { feature.value($0)! }, x: r.map { $0.minutes })
                out.append(contentsOf: zip(r, res).map { ($0.0.stage!, $0.1) })
            }
            return out
        case .hrAdjusted:
            guard feature != .hr else { return [] }
            let r = sleep.filter { $0.hr != nil }
            let res = Separation.residuals(y: r.map { feature.value($0)! }, x: r.map { $0.hr! })
            return zip(r, res).map { ($0.0.stage!, $0.1) }
        case .recipeAdjusted:
            // Only the two R-R features are asked whether they add anything to the recipe's existing inputs; for
            // an existing input the question is circular.
            guard feature == .lnRmssd || feature == .lnLfHf else { return [] }
            let r = sleep.filter { $0.hr != nil && $0.hrVar != nil && $0.respReg != nil }
            let res = Separation.residuals(y: r.map { feature.value($0)! },
                                           covariates: r.map { [$0.hr!, $0.hrVar!, $0.respReg!] })
            return zip(r, res).map { ($0.0.stage!, $0.1) }
        case .eventAdjusted:
            let res = Separation.residuals(y: sleep.map { feature.value($0)! },
                                           covariates: sleep.map { [Double($0.eventEpochs)] })
            return zip(sleep, res).map { ($0.0.stage!, $0.1) }
        }
    }

    /// One patient's contrast, or nil when a side has fewer than `minEpochs` epochs or no expectation exists.
    static func contrast(_ feature: SepFeature, _ variant: SepVariant, _ a: String, _ b: String,
                         subject: String, _ epochs: [RRStageEpoch]) -> SubjectContrast? {
        guard let high = feature.expectedHigher(a, b) else { return nil }
        let low = high == a ? b : a
        let s = series(feature, variant, epochs)
        let hv = s.filter { $0.stage == high }.map { $0.value }
        let lv = s.filter { $0.stage == low }.map { $0.value }
        guard hv.count >= minEpochs, lv.count >= minEpochs else { return nil }
        return SubjectContrast(subject: subject, nHigh: hv.count, nLow: lv.count,
                               auc: Separation.auc(hv, lv), d: Separation.cohenD(hv, lv))
    }

    struct Summary {
        let subjects: Int
        let medianAUC: Double, q1: Double, q3: Double
        let above: Int          // subjects whose AUC is above 0.5 (the recipe's direction holds)
        let signP: Double
        let meanD: Double
    }

    static func summarise(_ rows: [SubjectContrast]) -> Summary {
        let aucs = rows.map { $0.auc }.filter { !$0.isNaN }
        let q = Separation.quartiles(aucs)
        let above = aucs.filter { $0 > 0.5 }.count, below = aucs.filter { $0 < 0.5 }.count
        return Summary(subjects: aucs.count, medianAUC: q.median, q1: q.q1, q3: q.q3, above: above,
                       signP: Separation.signTestP(positive: above, negative: below),
                       meanD: mean(rows.map { $0.d }.filter { !$0.isNaN }))
    }
}

// MARK: - Report

enum RRStageReport {

    static func run(dir: String) -> Bool {
        let ids = SlpdbRecord.ids(in: dir)
        guard !ids.isEmpty else {
            FileHandle.standardError.write(Data("no *.stages.csv under \(dir) — run scripts/slpdb_export.py first\n".utf8))
            return false
        }
        var loaded = [[RRStageEpoch]?](repeating: nil, count: ids.count)
        loaded.withUnsafeMutableBufferPointer { buf in
            let out = buf
            DispatchQueue.concurrentPerform(iterations: ids.count) { i in
                out[i] = SlpdbRecord.load(dir: dir, id: ids[i])?.features()
            }
        }
        let all = loaded.compactMap { $0 }.flatMap { $0 }
        guard !all.isEmpty else { FileHandle.standardError.write(Data("no featurisable record\n".utf8)); return false }
        let bySubject = Dictionary(grouping: all, by: { $0.subject })
        let subjects = bySubject.keys.sorted()

        print("""

        ================================================================================
        RR-STAGE. DO ln(RMSSD) AND ln(LF/HF) SEPARATE DEEP FROM REM ON A PSG WITH REAL R-R?
        ================================================================================
        MIT-BIH Polysomnographic Database (Ichimaru & Moody 1999; PhysioNet, ODC-By 1.0). Records: \(ids.count),
        patients: \(subjects.count) (slp01a/b and slp02a/b are two segments of one patient each).
        Features come from the recipe's own extraction (`V2Recipe.stageEpochsDetailed`, C3 terms on): a centred
        5-minute window, the app's R-R cleaning, RMSSD and Lomb-Scargle LF/HF. HR is derived from the beats.
        An AUC is oriented to the direction the RECIPE assumes (stated per row): above 0.5 means that
        assumption holds in that patient, below 0.5 means the opposite holds.
        """)

        // Data summary.
        let scored = all.filter { $0.stage != nil }
        print("\n    scored epochs \(scored.count) of \(all.count) featurised;  " + ["wake", "light", "deep", "rem"].map { st in
            let n = scored.filter { $0.stage == st }.count
            return "\(st) \(n) (\(f(Double(n) / Double(max(1, scored.count)) * 100, 4, 1)) %)"
        }.joined(separator: "  "))
        let withRmssd = scored.filter { $0.lnRmssd != nil }.count, withLfHf = scored.filter { $0.lnLfHf != nil }.count
        print("    epochs with ln RMSSD \(f(Double(withRmssd) / Double(max(1, scored.count)) * 100, 5, 1)) %,  with ln LF/HF \(f(Double(withLfHf) / Double(max(1, scored.count)) * 100, 5, 1)) %,  window free of annotated apnoea/hypopnea \(f(Double(scored.filter { $0.eventFree }.count) / Double(max(1, scored.count)) * 100, 5, 1)) %")

        // Per-stage means, one number per patient first.
        print("\n    PER-STAGE LEVELS (mean over patients of each patient's own mean; ± spread across patients; patients with >= \(RRStageAnalysis.minEpochs) epochs)")
        print("    stage     n    ln RMSSD          ln LF/HF          HR (bpm)")
        for st in ["wake", "light", "deep", "rem"] {
            func level(_ feat: SepFeature) -> (Double, Double, Int) {
                let per = subjects.compactMap { s -> Double? in
                    let v = bySubject[s]!.filter { $0.stage == st }.compactMap { feat.value($0) }
                    return v.count >= RRStageAnalysis.minEpochs ? mean(v) : nil
                }
                return (mean(per), sd(per), per.count)
            }
            let r = level(.lnRmssd), l = level(.lnLfHf), h = level(.hr)
            print("      \(st.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(format: "%2d", r.2))   \(f(r.0, 6, 2)) ± \(f(r.1, 4, 2))     \(f(l.0, 6, 2)) ± \(f(l.1, 4, 2))     \(f(h.0, 6, 1)) ± \(f(h.1, 4, 1))")
        }

        // Per-patient table for the contrast C3 acts on.
        print("\n    PER PATIENT, DEEP vs REM, all windows. AUC oriented to the recipe's assumption (higher stage in the header).")
        print("    patient   n deep  n REM   lnRMSSD deep>  d     lnLF/HF REM>   d     HR REM>   HR-spread REM>   resp-reg deep>")
        var excluded: [String] = []
        for s in subjects {
            let eps = bySubject[s]!
            func cell(_ feat: SepFeature) -> SubjectContrast? {
                RRStageAnalysis.contrast(feat, .all, "deep", "rem", subject: s, eps)
            }
            let nd = eps.filter { $0.stage == "deep" && $0.lnRmssd != nil }.count
            let nr = eps.filter { $0.stage == "rem" && $0.lnRmssd != nil }.count
            guard let rm = cell(.lnRmssd) else {
                excluded.append("\(s) (deep \(nd), REM \(nr))")
                continue
            }
            let lh = cell(.lnLfHf), h = cell(.hr), hv = cell(.hrVar), rg = cell(.respReg)
            func a(_ c: SubjectContrast?) -> String { c.map { f($0.auc, 6, 2) } ?? "   n/a" }
            func dd(_ c: SubjectContrast?) -> String { c.map { f($0.d, 5, 2) } ?? "  n/a" }
            print("      \(s.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(format: "%5d", rm.nHigh)) \(String(format: "%6d", rm.nLow))   \(a(rm))      \(dd(rm))   \(a(lh))      \(dd(lh))   \(a(h))   \(a(hv))        \(a(rg))")
        }
        if !excluded.isEmpty { print("    below \(RRStageAnalysis.minEpochs) featurised epochs of deep or REM, left out: " + excluded.joined(separator: ", ")) }

        // Cohort summaries per variant and contrast.
        for variant in SepVariant.allCases {
            print("\n    \(variant.label.uppercased())")
            print("    contrast        feature (expected higher)         patients  median AUC [Q1-Q3]  AUC>0.5   sign p   mean d")
            for (a, b) in RRStageAnalysis.contrasts {
                for feat in SepFeature.allCases {
                    guard let high = feat.expectedHigher(a, b) else { continue }
                    if variant == .hrAdjusted && feat == .hr { continue }
                    if variant == .recipeAdjusted && !(feat == .lnRmssd || feat == .lnLfHf) { continue }
                    let rows = subjects.compactMap {
                        RRStageAnalysis.contrast(feat, variant, a, b, subject: $0, bySubject[$0]!)
                    }
                    guard !rows.isEmpty else { continue }
                    let s = RRStageAnalysis.summarise(rows)
                    let name = "\(a) vs \(b)".padding(toLength: 15, withPad: " ", startingAt: 0)
                    let feature = "\(feat.label) (\(high))".padding(toLength: 34, withPad: " ", startingAt: 0)
                    print("    \(name) \(feature) \(String(format: "%5d", s.subjects))    \(f(s.medianAUC, 5, 2)) [\(f(s.q1, 4, 2))-\(f(s.q3, 4, 2))]   \(String(format: "%2d", s.above))/\(String(format: "%-2d", s.subjects))   \(f(s.signP, 6, 3))  \(f(s.meanD, 6, 2))")
                }
            }
        }

        print("""

        HOW TO READ THIS. A feature "separates" two stages for a patient when the AUC is clearly away from 0.5 in
        the direction the recipe assumes. The sign test counts patients, never epochs: 5-minute windows that
        slide by 30 s share 90 % of their beats, so an epoch-level p-value would only measure the overlap. With
        so few patients the test cannot reject unless nearly all agree, and "not significant" is "cannot tell".
        The adjusted blocks ask whether what separates the stages is the feature itself or something else that
        travels with the stage: the clock (deep early, REM late; a LINEAR trend only), the heart rate, the
        recipe's other cardiac inputs read together, or the apnoeas and hypopneas this cohort is full of.
        """)
        return true
    }
}
