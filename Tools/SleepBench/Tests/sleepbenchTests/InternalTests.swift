import XCTest
import SleepRecipe
import WhoopProtocol
@testable import sleepbench

/// The helpers behind sections H-K, on synthetic nights only.
final class InternalTests: XCTestCase {

    /// Five hours with slow heart-rate cycles, motion bursts every so often, and a beat stream whose
    /// variability follows the cycle. Nothing here comes from a person.
    private func night(seed: UInt64 = 1, hours: Double = 5) -> NightInput {
        var g = SplitMix64(seed: seed)
        let start = 1_700_000_000 - 1_700_000_000 % 30
        let end = start + Int(hours * 3600)
        var hr: [HRSample] = [], grav: [GravitySample] = [], rr: [RRInterval] = []
        var t = Double(start)
        for s in start..<end {
            let phase = Double(s - start) / 5400.0 * 2 * .pi
            let bpm = 52 + 5 * sin(phase) + g.double(-1.5, 1.5)
            hr.append(HRSample(ts: s, bpm: Int(bpm.rounded())))
            let burst = (s - start) % 2400 < 90
            grav.append(GravitySample(ts: s, x: burst ? g.double(-0.4, 0.4) : 0.001 * g.double(-1, 1),
                                      y: burst ? g.double(-0.4, 0.4) : 0.001 * g.double(-1, 1), z: 1))
            if Double(s) >= t {
                let ms = 60000 / bpm + (s % 2 == 0 ? 25 : -25) * (1 + sin(phase))
                rr.append(RRInterval(ts: s, rrMs: Int(ms.rounded())))
                t += ms / 1000
            }
        }
        return NightInput(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: [])
    }

    // MARK: Statistics

    func testSignTestMatchesKnownBinomialValues() {
        XCTAssertEqual(Sign.p(wins: 0, losses: 0), 1)
        XCTAssertEqual(Sign.p(wins: 5, losses: 5), 1, accuracy: 1e-12)
        XCTAssertEqual(Sign.p(wins: 9, losses: 1), 2 * 11.0 / 1024.0, accuracy: 1e-12)   // 2·(1+10)/2^10
        XCTAssertEqual(Sign.p(wins: 10, losses: 0), 2.0 / 1024.0, accuracy: 1e-12)
        XCTAssertEqual(Sign.p(wins: 1, losses: 9), Sign.p(wins: 9, losses: 1), accuracy: 1e-12)
    }

    func testCompareCountsTiesAndSkipsNonFinite() {
        let r = Sign.compare([1, 2, 3, .nan, 5], [2, 2, 1, 9, 6])
        XCTAssertEqual(r.wins, 2); XCTAssertEqual(r.losses, 1); XCTAssertEqual(r.ties, 1)
    }

    func testKappaAndAgreementOfIdenticalAndDifferingLabels() {
        let a = ["wake", "light", "deep", "rem", "light", "light", "deep", "rem"]
        XCTAssertEqual(labelKappa(a, a), 1, accuracy: 1e-12)
        XCTAssertEqual(labelAgreement(a, a), 1)
        var b = a; b[1] = "rem"
        XCTAssertLessThan(labelKappa(a, b), 1)
        XCTAssertEqual(labelAgreement(a, b), 7.0 / 8.0, accuracy: 1e-12)
    }

    // MARK: Staging

    func testCandidateLabelsUseTheBenchVocabularyAndAreRepeatable() {
        let n = night()
        let a = Candidate.labels(n, .shipped), b = Candidate.labels(n, .shipped)
        XCTAssertEqual(a, b, "same input, same labels")
        XCTAssertEqual(a.count, epochCount(start: n.start, end: n.end))
        XCTAssertTrue(Set(a).isSubset(of: Set(stageOrder)), "\(Set(a))")
    }

    // MARK: Band reference

    func testBandConfusionExcludesStillAndMapsAsleepAndWake() {
        let labels = ["wake", "light", "light", "wake", "deep"]
        let band =   [0,      2,       1,       2,      3]        // wake, asleep, still(excluded), asleep, up
        let c = bandConfusion(labels, band: band)
        XCTAssertEqual(c.total, 4)
        XCTAssertEqual(c.m[0][0], 1)   // band wake  & stager wake
        XCTAssertEqual(c.m[1][1], 1)   // band sleep & stager sleep
        XCTAssertEqual(c.m[1][0], 1)   // band sleep & stager wake
        XCTAssertEqual(c.m[0][1], 1)   // band up    & stager sleep
    }

    // MARK: Sensitivity

    func testSelfLoopKnobKeepsEveryRowSummingToOne() {
        var c = RecipeConfig.shipped
        Knob.selfLoops.apply(&c, 1.1)
        for (from, row) in c.transition {
            XCTAssertEqual(row.values.reduce(0, +), 1, accuracy: 1e-9, from)
            XCTAssertGreaterThan(row[from]!, RecipeConfig.shipped.transition[from]![from]!, from)
        }
    }

    func testScaledKnobTouchesOnlyItsOwnField() {
        var c = RecipeConfig.shipped
        Knob.scaled("respWeight", \.respWeight).apply(&c, 1.1)
        XCTAssertEqual(c.respWeight, RecipeConfig.shipped.respWeight * 1.1, accuracy: 1e-12)
        XCTAssertEqual(c.deepGateThresh, RecipeConfig.shipped.deepGateThresh)
    }

    func testSensitivitySkipsSwitchedOffKnobsAndFactorOneIsIdentity() {
        let n = night(hours: 2)
        let base = [Candidate.labels(n, .shipped)]
        let rows = Sensitivity.run(inputs: [n], base: base, cfg: .shipped, factors: [1.0],
                                   knobs: [Knob.scaled("rmssdWeight", \.rmssdWeight),
                                           Knob.scaled("respWeight", \.respWeight)])
        XCTAssertEqual(rows.map { $0.knob }, ["respWeight"], "rmssdWeight is 0 in shipped, so it has no sensitivity")
        XCTAssertEqual(rows[0].kappaMedian, 1, accuracy: 1e-12)
        XCTAssertEqual(rows[0].meanAbsDeltaMin.values.reduce(0, +), 0, accuracy: 1e-12)
    }

    func testSensitivityUsesTheInjectedStagerAndReportsTheWorstNight() {
        let first = night(seed: 1, hours: 1)
        var second = night(seed: 2, hours: 1)
        second.start += 7200; second.end += 7200
        let base = [[String](repeating: "light", count: 120), [String](repeating: "light", count: 120)]
        // A stub stager that changes the second night only: the worst-night kappa and the deep-minute change
        // must show it, and the first night must stay untouched.
        let rows = Sensitivity.run(inputs: [first, second], base: base, cfg: .shipped, factors: [1.1],
                                   knobs: [Knob.scaled("respWeight", \.respWeight)],
                                   stage: { input, _ in
            input.start == second.start
                ? [String](repeating: "light", count: 60) + [String](repeating: "deep", count: 60)
                : [String](repeating: "light", count: 120) })
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].meanAbsDeltaMin["deep"] ?? 0, 0.5 * 30, accuracy: 1e-9)   // (0 + 30 min) / 2 nights
        XCTAssertLessThan(rows[0].kappaMin, 1)
    }

    // MARK: Damage

    func testDamageIsDeterministicAndRemovesWhatItSays() {
        let n = night(hours: 2)
        let d = Damage.standard
        let a = d[0].apply(n, 5), b = d[0].apply(n, 5)
        XCTAssertEqual(a.hr.map { $0.ts }, b.hr.map { $0.ts })
        XCTAssertLessThan(a.hr.count, n.hr.count)
        XCTAssertEqual(a.rr.count, n.rr.count)
        let hole = d.first { $0.name.hasPrefix("30-min") }!.apply(n, 1)
        XCTAssertEqual(n.grav.count - hole.grav.count, 30 * 60)
        XCTAssertEqual(hole.hr.count, n.hr.count)
    }

    func testRobustnessOfAnUndamagedNightIsPerfectAgreement() {
        let n = night(hours: 2)
        let clean = [Candidate.labels(n, .shipped)]
        let identity = Damage(name: "none") { input, _ in input }
        let r = Robustness.run(inputs: [n], clean: clean, cfg: .shipped, damages: [identity])
        XCTAssertEqual(r[0].kappas[0], 1, accuracy: 1e-12)
    }

    func testExtendingTheWindowReturnsTheOriginalInteriorLength() {
        var n = night(hours: 3)
        // Carve the original window out of a stream that already reaches 30 minutes further on both sides.
        let inner = NightInput(start: n.start + 1800, end: n.end - 1800,
                               grav: n.grav, hr: n.hr, rr: n.rr, resp: [])
        n = inner
        let cut = Robustness.interiorAfterExtending(inner, by: 900, cfg: .shipped)
        XCTAssertEqual(cut.count, epochCount(start: inner.start, end: inner.end))
        XCTAssertTrue(Set(cut).isSubset(of: Set(stageOrder)))
    }

    // MARK: Export

    func testStageExportRunLengthEncodesTheGridAndCoversTheWindow() {
        let labels = ["wake", "wake", "light", "light", "light", "deep"]
        let csv = StageExport.csv(start: 1000, end: 1180, labels: labels)
        XCTAssertEqual(csv, "N,1000,1180\nS,1000,1060,wake\nS,1060,1150,light\nS,1150,1180,deep\n")
    }

    func testStageExportClampsTheLastSegmentToTheWindowEnd() {
        XCTAssertEqual(StageExport.csv(start: 0, end: 70, labels: ["light", "light", "deep"]),
                       "N,0,70\nS,0,60,light\nS,60,70,deep\n")
    }
}
