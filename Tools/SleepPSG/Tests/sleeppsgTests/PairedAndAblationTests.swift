import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import SleepRecipe
@testable import sleeppsg

/// The paired comparison, the seeded damage and the prior ablations, pinned on small or synthetic inputs. No
/// dataset is read and nothing here is, or derives from, a wearer's data.
final class PairedAndAblationTests: XCTestCase {

    // MARK: - Paired comparison

    func testPairedKappaAndMinutesOnAHandComputedSubject() {
        let truth = [["wake", "light", "light", "deep", "rem", "rem"]]
        let base = [["wake", "light", "light", "light", "rem", "light"]]
        let cand = [["wake", "light", "light", "deep", "rem", "rem"]]
        // Baseline: 6 epochs, 4 right. pe = (1/6)(1/6) + (2/6)(4/6) + 0 + (2/6)(1/6) = 11/36, po = 24/36,
        // kappa = 13/25 = 0.52. The candidate is perfect (kappa 1), so the change is +0.48.
        let r = PairedComparison.compare(truth: truth, base: base, cand: cand, bootstrap: 0)
        XCTAssertEqual(r.kappaBase[0], 13.0 / 25.0, accuracy: 1e-12)
        XCTAssertEqual(r.kappaCand[0], 1.0, accuracy: 1e-12)
        XCTAssertEqual(r.meanDelta, 0.48, accuracy: 1e-12)
        XCTAssertEqual(r.wins, 1); XCTAssertEqual(r.losses, 0); XCTAssertEqual(r.ties, 0)
        // Deep: truth 1 epoch (0.5 min), baseline 0, candidate 1. REM: truth 2, baseline 1, candidate 2.
        let deep = r.stages["deep"]!
        XCTAssertEqual(deep.meanShift, 0.5, accuracy: 1e-12)
        XCTAssertEqual(deep.errorBase, 0.5, accuracy: 1e-12)
        XCTAssertEqual(deep.errorCand, 0.0, accuracy: 1e-12)
        XCTAssertEqual(deep.closer, 1); XCTAssertEqual(deep.farther, 0)
        XCTAssertEqual(r.stages["rem"]!.meanShift, 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.stages["light"]!.meanShift, -1.0, accuracy: 1e-12)   // 4 -> 2 light epochs
        XCTAssertEqual(r.stages["light"]!.worstShift, 1.0, accuracy: 1e-12)
    }

    func testIdenticalLabelsAreATieNotAWin() {
        let truth = [["wake", "light", "deep", "rem"], ["light", "light", "rem", "wake"]]
        let r = PairedComparison.compare(truth: truth, base: truth, cand: truth, bootstrap: 0)
        XCTAssertEqual(r.ties, 2); XCTAssertEqual(r.wins, 0); XCTAssertEqual(r.losses, 0)
        XCTAssertEqual(r.signP, 1.0, accuracy: 1e-12)
        XCTAssertEqual(r.meanDelta, 0.0, accuracy: 1e-12)
    }

    func testASubjectWithOneClassHasNoKappaAndIsLeftOutOfIt() {
        let truth = [["light", "light", "light"], ["wake", "light", "light", "deep"]]
        let base = [["light", "light", "light"], ["wake", "light", "light", "light"]]
        let cand = [["light", "light", "light"], ["wake", "light", "light", "deep"]]
        let r = PairedComparison.compare(truth: truth, base: base, cand: cand, bootstrap: 0)
        XCTAssertTrue(r.kappaBase[0].isNaN)
        XCTAssertEqual(r.wins, 1)                  // only the second subject is judged
        XCTAssertEqual(r.stages["light"]!.meanShift, -0.25, accuracy: 1e-12)   // (0 + -0.5 min) / 2
    }

    func testBootstrapIntervalContainsTheMeanAndIsDeterministic() {
        // Six subjects whose kappa the candidate raises by different amounts.
        var truth: [[String]] = [], base: [[String]] = [], cand: [[String]] = []
        for k in 0..<6 {
            let t = (0..<40).map { ["wake", "light", "deep", "rem"][($0 / 3 + k) % 4] }
            var b = t, c = t
            for i in 0..<(8 + k) { b[(i * 5) % 40] = "light" }
            for i in 0..<(4 + k) { c[(i * 5) % 40] = "light" }
            truth.append(t); base.append(b); cand.append(c)
        }
        let r1 = PairedComparison.compare(truth: truth, base: base, cand: cand)
        let r2 = PairedComparison.compare(truth: truth, base: base, cand: cand)
        XCTAssertEqual(r1.ciLow, r2.ciLow); XCTAssertEqual(r1.ciHigh, r2.ciHigh)
        XCTAssertLessThanOrEqual(r1.ciLow, r1.meanDelta); XCTAssertGreaterThanOrEqual(r1.ciHigh, r1.meanDelta)
        XCTAssertGreaterThan(r1.ciLow, 0, "the candidate wins on every one of these subjects")
    }

    // MARK: - Seeded damage

    func testSingleHoleIsExactInLengthInsideTheSpanAndDeterministic() {
        let h = Perturb.singleHole(from: 1000, to: 5000, length: 900, seed: 7)
        XCTAssertEqual(h.to - h.from, 900)
        XCTAssertGreaterThanOrEqual(h.from, 1000); XCTAssertLessThanOrEqual(h.to, 5000)
        let again = Perturb.singleHole(from: 1000, to: 5000, length: 900, seed: 7)
        XCTAssertEqual(h.from, again.from)
        XCTAssertNotEqual(Perturb.singleHole(from: 1000, to: 5000, length: 900, seed: 8).from, h.from)
        // A hole longer than the span covers the span.
        let all = Perturb.singleHole(from: 0, to: 600, length: 3600, seed: 1)
        XCTAssertEqual(all.from, 0); XCTAssertEqual(all.to, 600)
    }

    func testBurstHolesAreDisjointOnTheGridAndCoverTheRequestedFraction() {
        let holes = Perturb.burstHoles(from: 0, to: 12_000, fraction: 0.25, burstSeconds: 120, seed: 3)
        XCTAssertEqual(holes.count, 25)            // 100 slots of 120 s, a quarter of them
        XCTAssertEqual(holes.reduce(0) { $0 + $1.to - $1.from }, 25 * 120)
        for (a, b) in zip(holes, holes.dropFirst()) { XCTAssertLessThanOrEqual(a.to, b.from) }
        XCTAssertTrue(holes.allSatisfy { $0.from % 120 == 0 && $0.to - $0.from == 120 })
        XCTAssertEqual(holes.map { $0.from }, Perturb.burstHoles(from: 0, to: 12_000, fraction: 0.25, burstSeconds: 120, seed: 3).map { $0.from })
        XCTAssertTrue(Perturb.burstHoles(from: 0, to: 12_000, fraction: 0, burstSeconds: 120, seed: 3).isEmpty)
        XCTAssertEqual(Perturb.burstHoles(from: 0, to: 600, fraction: 1, burstSeconds: 120, seed: 3).count, 5)
    }

    func testPerSubjectSeedsDifferByIdAndRepeatByIdentity() {
        XCTAssertEqual(Perturb.seed(mixing: 1, with: "a"), Perturb.seed(mixing: 1, with: "a"))
        XCTAssertNotEqual(Perturb.seed(mixing: 1, with: "a"), Perturb.seed(mixing: 1, with: "b"))
    }

    private func subject(_ id: String = "x") -> PSGSubject {
        let start = SleepAccel.timeBase, end = start + 6 * 3600
        let grav = (0..<(6 * 3600)).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
        let hr = (0..<(6 * 3600 / 5)).map { HRSample(ts: start + $0 * 5, bpm: 55) }
        return PSGSubject(id: id, start: start, end: end, grav: grav, hr: hr,
                          truth: [String?](repeating: "light", count: 6 * 120))
    }

    func testEachScenarioDamagesOnlyWhatItNamesAndTheSameWayEveryTime() {
        let s = subject()
        for sc in DropoutScenario.all {
            let d = sc.apply(to: s), again = sc.apply(to: s)
            XCTAssertEqual(d.grav.map { $0.ts }, again.grav.map { $0.ts }, sc.name)
            XCTAssertEqual(d.hr.map { $0.ts }, again.hr.map { $0.ts }, sc.name)
            XCTAssertEqual(d.truth, s.truth, sc.name)
            if sc.gravity == nil { XCTAssertEqual(d.grav.count, s.grav.count, sc.name) } else { XCTAssertLessThan(d.grav.count, s.grav.count, sc.name) }
            if sc.heartRate == nil { XCTAssertEqual(d.hr.count, s.hr.count, sc.name) } else { XCTAssertLessThan(d.hr.count, s.hr.count, sc.name) }
        }
        let g30 = DropoutScenario.all[1].apply(to: s)
        XCTAssertEqual(s.grav.count - g30.grav.count, 30 * 60, "a 30-minute gravity hole removes exactly 1800 one-second samples")
        let loss = DropoutScenario.all.first { $0.name == "HR samples lost 30 %" }!.apply(to: s)
        XCTAssertEqual(Double(s.hr.count - loss.hr.count) / Double(s.hr.count), 0.30, accuracy: 0.02)
        // Different subjects get different damage from the same scenario.
        XCTAssertNotEqual(DropoutScenario.all[1].apply(to: subject("x")).grav.map { $0.ts },
                          DropoutScenario.all[1].apply(to: subject("y")).grav.map { $0.ts })
    }

    // MARK: - Ablations

    private let corpus = PortValidation.corpus(seed: 0xAB1A, randomNights: 8)
        .filter { !$0.name.hasPrefix("degenerate") }

    private func labels(_ n: SyntheticNight, _ cfg: RecipeConfig) -> [String] {
        V2Recipe.stageEpochsDetailed(start: n.start, end: n.end, grav: n.grav, hr: n.hr, rr: n.rr, resp: n.resp, cfg: cfg).labels
    }

    func testAblationsAreSingleNamedChanges() {
        let base = Variants.incumbent
        var c = Variants.withoutCyclePrior(base).config; c.cyclePriorScale = 1
        XCTAssertEqual(c, base.config)
        c = Variants.withoutRemGuard(base).config; c.remLatencyPenalty = base.config.remLatencyPenalty
        XCTAssertEqual(c, base.config)
        XCTAssertEqual(Variants.withoutCycleAndGuard(base).config.cyclePriorScale, 0)
        XCTAssertEqual(Variants.withoutCycleAndGuard(base).config.remLatencyPenalty, 0)
        XCTAssertEqual(RecipeConfig.shipped.cyclePriorScale, 1.0, "shipped must keep the switch neutral")
        // The signal-free control keeps every prior, the cycle prior and the guard.
        let s = Variants.withoutSignals(base).config
        XCTAssertEqual(s.priorLight, base.config.priorLight)
        XCTAssertEqual(s.cyclePriorScale, 1)
        XCTAssertEqual(s.remLatencyPenalty, base.config.remLatencyPenalty)
        XCTAssertEqual(s.transition, base.config.transition)
        XCTAssertEqual(Variants.ablations.count, 11)
    }

    func testCyclePriorAtScaleOneIsTheShippedRecipeAndAtZeroItMovesLabels() {
        var moved = 0
        for n in corpus.prefix(4) {
            var one = RecipeConfig.shipped; one.cyclePriorScale = 1.0
            XCTAssertEqual(labels(n, one), labels(n, .shipped), n.name)
            if labels(n, Variants.withoutCyclePrior(Variants.incumbent).config) != labels(n, .shipped) { moved += 1 }
        }
        XCTAssertGreaterThan(moved, 0, "removing the cycle prior changed no night; the switch is dead code")
    }

    func testTheFloorLabelsEverythingLight() {
        // Per-epoch signals off, cycle prior off, guard off: only the base priors and the transition matrix are
        // left, and light has the largest prior, so no epoch can leave it.
        let floor = Variants.ablations.last!.config
        for n in corpus.prefix(4) {
            XCTAssertTrue(labels(n, floor).allSatisfy { $0 == "light" }, n.name)
        }
    }
}
