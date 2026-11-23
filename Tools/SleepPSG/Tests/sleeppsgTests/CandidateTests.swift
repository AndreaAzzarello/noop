import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import SleepRecipe
@testable import sleeppsg

/// What the candidate switches do, and — as important — what they must NOT do. Every night here is synthetic
/// (`PortValidation.corpus` or built in this file); nothing is, or is derived from, a wearer's data.
///
/// Read the limits of these tests plainly: they show a switch is inert when it should be, and that a feature
/// tracks the input it claims to track. They say nothing about whether a candidate stages real sleep better.
final class CandidateTests: XCTestCase {

    private let corpus = PortValidation.corpus(seed: 0xC1C1, randomNights: 12)
        .filter { !$0.name.hasPrefix("degenerate") }

    private func labels(_ n: SyntheticNight, _ cfg: RecipeConfig, grav: [GravitySample]? = nil,
                        rr: [RRInterval]? = nil) -> [String] {
        V2Recipe.stageEpochsDetailed(start: n.start, end: n.end, grav: grav ?? n.grav, hr: n.hr,
                                     rr: rr ?? n.rr, resp: n.resp, cfg: cfg).labels
    }

    private func differing(_ a: [String], _ b: [String]) -> Int {
        XCTAssertEqual(a.count, b.count)
        return zip(a, b).filter { $0 != $1 }.count
    }

    // MARK: C1

    func testC1ChangesNothingWhenGravityIsComplete() {
        for n in corpus.prefix(6) {
            XCTAssertEqual(differing(labels(n, .shipped), labels(n, Variants.c1MissingGravityNeutral.config)), 0, n.name)
        }
    }

    /// With no gravity at all, every epoch already ties at moveFrac 0 and the shipped z-score collapses to 0,
    /// so C1 is a no-op by construction — which is why it cannot help a night recorded without history.
    func testC1ChangesNothingWhenThereIsNoGravityAtAll() {
        for n in corpus.prefix(6) {
            XCTAssertEqual(differing(labels(n, .shipped, grav: []),
                                     labels(n, Variants.c1MissingGravityNeutral.config, grav: [])), 0, n.name)
        }
    }

    func testC1ChangesLabelsWhenGravityIsPartlyMissing() {
        var changed = 0
        for n in corpus.prefix(6) {
            let mid = n.start + (n.end - n.start) / 2
            let hole = Perturb.gravityHole(n.grav, from: mid - 1200, to: mid + 1200)
            if differing(labels(n, .shipped, grav: hole), labels(n, Variants.c1MissingGravityNeutral.config, grav: hole)) > 0 {
                changed += 1
            }
        }
        XCTAssertGreaterThan(changed, 0, "C1 never fired on a 40-minute gravity hole; the switch is dead code")
    }

    // MARK: C3

    func testC3SwitchesAreOffInShippedAndDoNoExtraWork() {
        let n = corpus[0]
        let feats = V2Recipe.features(start: n.start, end: n.end, grav: n.grav, hr: n.hr, rr: n.rr)
        XCTAssertTrue(feats.allSatisfy { $0.lnRmssd == nil && $0.lnLfHf == nil })
    }

    func testC3ChangesNothingWithoutRR() {
        for n in corpus.prefix(5) {
            let base = labels(n, .shipped, rr: [])
            XCTAssertEqual(differing(base, labels(n, Variants.c3aRmssd.config, rr: [])), 0, n.name)
            XCTAssertEqual(differing(base, labels(n, Variants.c3bRmssdLfHf.config, rr: [])), 0, n.name)
        }
    }

    /// A tachogram whose beats alternate base ± `d` has RMSSD = 2d exactly; the feature has to recover SEVERAL
    /// injected levels in order, not one that happens to match.
    func testLnRmssdFeatureRecoversSeveralInjectedLevels() {
        var seen: [Double] = []
        for d in [8.0, 16.0, 32.0, 64.0] {
            let rr = Synth.rr(start: 0, end: 1800, baseMs: 1000) { _ in d }
            let feats = V2Recipe.features(start: 0, end: 1800, grav: [], hr: Synth.hr(0, 1800, bpm: 60), rr: rr,
                                          cfg: Variants.c3aRmssd.config)
            let mid = feats[feats.count / 2]
            seen.append(mid.lnRmssd ?? .nan)
            XCTAssertEqual(mid.lnRmssd ?? .nan, log(2 * d), accuracy: 0.12, "injected RMSSD \(2 * d) ms")
        }
        XCTAssertEqual(seen, seen.sorted())
    }

    /// Respiratory (0.25 Hz) against slow (0.10 Hz) modulation of the same tachogram: ln(LF/HF) must rise as
    /// the slow share rises, across several mixes.
    func testLnLfHfFeatureTracksTheInjectedBalance() {
        var seen: [Double] = []
        for lfShare in [0.2, 0.5, 1.0, 2.0, 4.0] {
            let rr = Synth.rrTwoTone(start: 0, end: 1800, baseMs: 1000, lfAmp: 20 * lfShare, hfAmp: 20)
            let feats = V2Recipe.features(start: 0, end: 1800, grav: [], hr: Synth.hr(0, 1800, bpm: 60), rr: rr,
                                          cfg: Variants.c3bRmssdLfHf.config)
            seen.append(feats[feats.count / 2].lnLfHf ?? .nan)
        }
        XCTAssertFalse(seen.contains { $0.isNaN }, "\(seen)")
        XCTAssertEqual(seen, seen.sorted(), "\(seen)")
        XCTAssertGreaterThan(seen.last! - seen.first!, 2.0, "\(seen)")
    }

    /// Direction, against the shipped recipe on the SAME night: where beat-to-beat variability is high C3a may
    /// only add deep and remove REM, and where it is low only the reverse. The night is two halves with
    /// everything else tied (flat heart rate, no gravity), so the only thing that differs is the R-R. This is
    /// a property of the sign convention, not of accuracy. It also shows how strong the term is: on a
    /// two-valued input the z-score is exactly ±1 and, through the sticky transition matrix, the second half
    /// moves from a few REM epochs to almost all REM — read that as "weight 0.6 is not a small nudge", which
    /// is what the sensitivity section of the bench exists to size on real nights.
    func testC3MovesDeepAndRemInTheDeclaredDirection() {
        let end = 6 * 3600
        let rr = Synth.rr(start: 0, end: end, baseMs: 1090) { t in t < end / 2 ? 60 : 10 }
        let hr = Synth.hr(0, end, bpm: 55)
        func run(_ cfg: RecipeConfig) -> [String] {
            V2Recipe.stageEpochsDetailed(start: 0, end: end, grav: [], hr: hr, rr: rr, resp: [], cfg: cfg).labels
        }
        let base = run(.shipped), cand = run(Variants.c3aRmssd.config)
        let half = base.count / 2
        func count(_ out: [String], _ s: String, _ r: Range<Int>) -> Int { out[r].filter { $0 == s }.count }
        let first = 0..<half, second = half..<base.count
        XCTAssertLessThanOrEqual(count(cand, "rem", first), count(base, "rem", first))
        XCTAssertGreaterThanOrEqual(count(cand, "deep", first), count(base, "deep", first))
        XCTAssertGreaterThan(count(cand, "rem", second), count(base, "rem", second))
        XCTAssertLessThanOrEqual(count(cand, "deep", second), count(base, "deep", second))
    }
}

// MARK: - C5 window dependence

extension CandidateTests {

    /// A sleep period of 4 h flanked by 25 min of clear wake on each side (high heart rate, movement bursts).
    private var flankedNight: (grav: [GravitySample], hr: [HRSample], lead: Int, sleep: Int) {
        var g = SplitMix64(seed: 99)
        let lead = 25 * 60, sleep = 4 * 3600
        var hr: [HRSample] = [], grav: [GravitySample] = []
        for s in 0..<(lead + sleep + lead) {
            let asleep = s >= lead && s < lead + sleep
            let bpm = asleep ? 52 + 5 * sin(Double(s - lead) / 5400 * 2 * .pi) + g.double(-1.5, 1.5)
                             : 72 + g.double(-6, 6)
            hr.append(HRSample(ts: s, bpm: Int(bpm.rounded())))
            let burst = !asleep && s % 20 < 4
            grav.append(GravitySample(ts: s, x: burst ? g.double(-0.5, 0.5) : 0.001 * g.double(-1, 1),
                                      y: burst ? g.double(-0.5, 0.5) : 0.001 * g.double(-1, 1), z: 1))
        }
        return (grav, hr, lead, sleep)
    }

    /// Share of the sleep period's epochs that keep their label when the window is widened to include the wake
    /// on both sides. This is INVARIANCE, not accuracy: the same property would hold for a recipe that labelled
    /// everything light.
    private func interiorAgreement(_ cfg: RecipeConfig) -> Double {
        let n = flankedNight
        func run(_ a: Int, _ b: Int) -> [String] {
            V2Recipe.stageEpochsDetailed(start: a, end: b,
                grav: n.grav.filter { $0.ts >= a - 400 && $0.ts < b + 400 },
                hr: n.hr.filter { $0.ts >= a - 400 && $0.ts < b + 400 }, rr: [], resp: [], cfg: cfg).labels
        }
        let narrow = run(n.lead, n.lead + n.sleep), wide = run(0, n.lead * 2 + n.sleep)
        let interior = Array(wide[(n.lead / 30)..<(n.lead / 30 + narrow.count)])
        return Double(zip(narrow, interior).filter { $0 == $1 }.count) / Double(narrow.count)
    }

    /// Each C5 step takes one more window-dependent thing out of the labels, in order: robust centre and spread,
    /// then statistics over the sleep period only, then the cycle prior's clock inside the period. On a night with
    /// clear wake either side, the share of interior epochs that keep their label rises at every step, and with
    /// both anchors the interior is untouched.
    func testC5StepsRaiseWindowInvarianceInOrder() {
        let shipped = interiorAgreement(.shipped)
        let a = interiorAgreement(Variants.c5aRobustNormalisation.config)
        let b = interiorAgreement(Variants.c5bOnsetAnchoredStats.config)
        let c = interiorAgreement(Variants.c5cAnchoredClock.config)
        XCTAssertLessThan(shipped, 0.9, "the shipped recipe must actually be window-dependent here, or the test shows nothing")
        XCTAssertLessThan(shipped, a); XCTAssertLessThan(a, b); XCTAssertLessThan(b, c)
        XCTAssertEqual(c, 1.0, accuracy: 1e-12)
    }

    /// Without a decodable sleep period there is nothing to anchor on, so the anchored variants must fall back
    /// to the shipped labels rather than guess.
    func testAnchoredVariantsFallBackToShippedWhenThereIsNoSleepPeriod() {
        let n = PortValidation.degenerateNights().first { $0.name != "degenerate-no-coverage" }!
        let base = labels(n, .shipped)
        for v in [Variants.c5bOnsetAnchoredStats, Variants.c5cAnchoredClock] {
            XCTAssertEqual(labels(n, v.config).count, base.count, v.name)
        }
        let awake = (0..<600).map { HRSample(ts: $0, bpm: 90) }
        let moving = (0..<600).map { GravitySample(ts: $0, x: Double($0 % 7) * 0.2, y: 0, z: 1) }
        let shippedLabels = V2Recipe.stageEpochsDetailed(start: 0, end: 600, grav: moving, hr: awake, rr: [], resp: [], cfg: .shipped).labels
        let anchored = V2Recipe.stageEpochsDetailed(start: 0, end: 600, grav: moving, hr: awake, rr: [], resp: [],
                                                    cfg: Variants.c5cAnchoredClock.config).labels
        XCTAssertEqual(shippedLabels, anchored)
    }
}

/// Synthetic streams, shared by the candidate tests.
enum Synth {
    static func hr(_ from: Int, _ to: Int, bpm: Int) -> [HRSample] {
        (from..<to).map { HRSample(ts: $0, bpm: bpm) }
    }

    /// Beats alternating `baseMs ± d(t)`, stamped at the second they fall in.
    static func rr(start: Int, end: Int, baseMs: Double, d: (Int) -> Double) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(start), k = 0
        while t < Double(end) {
            let dev = d(Int(t)) * (k % 2 == 0 ? 1 : -1)
            let ms = baseMs + dev
            out.append(RRInterval(ts: Int(t), rrMs: Int(ms.rounded())))
            t += ms / 1000; k += 1
        }
        return out
    }

    /// A tachogram with a 0.10 Hz and a 0.25 Hz sinusoid of the given amplitudes (ms) on a `baseMs` mean.
    static func rrTwoTone(start: Int, end: Int, baseMs: Double, lfAmp: Double, hfAmp: Double) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(start)
        while t < Double(end) {
            let ms = baseMs + lfAmp * sin(2 * .pi * 0.10 * t) + hfAmp * sin(2 * .pi * 0.25 * t)
            out.append(RRInterval(ts: Int(t), rrMs: Int(ms.rounded())))
            t += ms / 1000
        }
        return out
    }
}
