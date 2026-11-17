import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

final class AutoWorkoutMotionGateTests: XCTestCase {
    private let start = 1_800_000_000

    private func workout(minutes: Int = 30, avg: Int = 120) -> DetectedWorkout {
        DetectedWorkout(startSec: start, endSec: start + minutes * 60, avgBpm: avg, peakBpm: avg + 20, durationMin: minutes)
    }

    /// One activity-class sample per second over `[from, to)`; `moving` of every 10 seconds carry class 1.
    private func steps(from: Int, to: Int, movingPerTen: Int, cls: Int = 1) -> [StepSample] {
        (from..<to).map { t in StepSample(ts: t, counter: 0, activityClass: (t - from) % 10 < movingPerTen ? cls : 0) }
    }

    private func tally(_ s: [StepSample], _ g: [GravitySample] = [], for w: DetectedWorkout) -> AutoWorkoutMotionGate.Tally {
        AutoWorkoutMotionGate.tally(steps: s, gravity: g, start: w.startSec, end: w.endSec)
    }

    private let standard = AutoWorkoutMotionGate.Settings.standard

    // MARK: Verdicts

    func testConfirmedWhenDurationIntensityAndMovementPass() {
        let w = workout()   // resting 50 + 45 = 95 <= 120
        let e = AutoWorkoutMotionGate.evaluate(w, restingBpm: 50,
            tally: tally(steps(from: w.startSec, to: w.endSec + 1, movingPerTen: 5), for: w), settings: standard)
        XCTAssertEqual(e.verdict, .confirmed)
        XCTAssertEqual(e.movingShare, 0.5, accuracy: 0.01)
        XCTAssertEqual(e.hrMargin, 70)
    }

    func testTooShortComesFirst() {
        let w = workout(minutes: 14, avg: 60)
        let e = AutoWorkoutMotionGate.evaluate(w, restingBpm: 50, tally: .init(seconds: 841, covered: 0, moving: 0), settings: standard)
        XCTAssertEqual(e.verdict, .tooShort)
    }

    func testLowIntensityBeatsMissingMotion() {
        let w = workout(avg: 80)   // margin 30 < 45
        let e = AutoWorkoutMotionGate.evaluate(w, restingBpm: 50, tally: .init(seconds: 1801, covered: 0, moving: 0), settings: standard)
        XCTAssertEqual(e.verdict, .lowIntensity)
    }

    func testNoMotionWhenMovingShareBelowTwentyPercent() {
        let w = workout()
        let e = AutoWorkoutMotionGate.evaluate(w, restingBpm: 50,
            tally: tally(steps(from: w.startSec, to: w.endSec + 1, movingPerTen: 1), for: w), settings: standard)
        XCTAssertEqual(e.verdict, .noMotion)
    }

    func testMotionMissingWhenCoverageBelowHalf() {
        let w = workout()
        let e = AutoWorkoutMotionGate.evaluate(w, restingBpm: 50,
            tally: tally(steps(from: w.startSec, to: w.startSec + 600, movingPerTen: 10), for: w), settings: standard)
        XCTAssertEqual(e.verdict, .motionMissing)
        XCTAssertLessThan(e.coverage, 0.5)
    }

    // MARK: Boundaries

    func testExactlyTwentyPercentMovingPasses() {
        let t = AutoWorkoutMotionGate.Tally(seconds: 1000, covered: 1000, moving: 200)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(), restingBpm: 50, tally: t, settings: standard).verdict, .confirmed)
        let below = AutoWorkoutMotionGate.Tally(seconds: 1000, covered: 1000, moving: 199)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(), restingBpm: 50, tally: below, settings: standard).verdict, .noMotion)
    }

    func testExactlyHalfCoveragePasses() {
        let ok = AutoWorkoutMotionGate.Tally(seconds: 1000, covered: 500, moving: 500)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(), restingBpm: 50, tally: ok, settings: standard).verdict, .confirmed)
        let low = AutoWorkoutMotionGate.Tally(seconds: 1000, covered: 499, moving: 499)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(), restingBpm: 50, tally: low, settings: standard).verdict, .motionMissing)
    }

    func testAverageExactlyRestingPlus45PassesAndOneBelowFails() {
        let t = AutoWorkoutMotionGate.Tally(seconds: 100, covered: 100, moving: 100)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(avg: 95), restingBpm: 50, tally: t, settings: standard).verdict, .confirmed)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(avg: 94), restingBpm: 50, tally: t, settings: standard).verdict, .lowIntensity)
    }

    func testDurationEqualToTheMinimumPasses() {
        let t = AutoWorkoutMotionGate.Tally(seconds: 100, covered: 100, moving: 100)
        let s = AutoWorkoutMotionGate.Settings(minMinutes: 20, requireMotion: true)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(minutes: 20), restingBpm: 50, tally: t, settings: s).verdict, .confirmed)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(minutes: 19), restingBpm: 50, tally: t, settings: s).verdict, .tooShort)
    }

    func testRestingNilFallsBackToSixty() {
        let t = AutoWorkoutMotionGate.Tally(seconds: 100, covered: 100, moving: 100)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(avg: 105), restingBpm: nil, tally: t, settings: standard).verdict, .confirmed)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(avg: 104), restingBpm: nil, tally: t, settings: standard).verdict, .lowIntensity)
    }

    // MARK: requireMotion off

    func testMovementOffIgnoresMissingAndLowMotionButKeepsDurationAndIntensity() {
        let off = AutoWorkoutMotionGate.Settings(minMinutes: 15, requireMotion: false)
        let none = AutoWorkoutMotionGate.Tally(seconds: 1800, covered: 0, moving: 0)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(), restingBpm: 50, tally: none, settings: off).verdict, .confirmed)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(avg: 80), restingBpm: 50, tally: none, settings: off).verdict, .lowIntensity)
        XCTAssertEqual(AutoWorkoutMotionGate.evaluate(workout(minutes: 10), restingBpm: 50, tally: none, settings: off).verdict, .tooShort)
    }

    // MARK: Which signal counts

    func testActivityClassTakesPriorityOverGravity() {
        let w = workout(minutes: 1)
        // Class 0 every second (still), while gravity swings wildly: still wins.
        let s = (w.startSec...w.endSec).map { StepSample(ts: $0, counter: 0, activityClass: 0) }
        let g = (w.startSec...w.endSec).map { GravitySample(ts: $0, x: Double($0 % 2) * 2, y: 0, z: 0) }
        let t = tally(s, g, for: w)
        XCTAssertEqual(t.covered, 61)
        XCTAssertEqual(t.moving, 0)
    }

    func testClassOneAndTwoCountAsMovingOthersDoNot() {
        let w = workout(minutes: 1)
        let s = [StepSample(ts: w.startSec, counter: 0, activityClass: 1),
                 StepSample(ts: w.startSec + 1, counter: 0, activityClass: 2),
                 StepSample(ts: w.startSec + 2, counter: 0, activityClass: 0),
                 StepSample(ts: w.startSec + 3, counter: 0, activityClass: 3)]
        let t = tally(s, for: w)
        XCTAssertEqual(t.covered, 4)
        XCTAssertEqual(t.moving, 2)
    }

    func testGravityFallbackWhenThereIsNoActivityClass() {
        let w = workout(minutes: 1)
        // Alternating gravity vectors 1 g apart: the 10 s mean of the delta stays above 0.20.
        let g = (w.startSec - 12...w.endSec).map { GravitySample(ts: $0, x: Double($0 % 2), y: 0, z: 0) }
        let t = tally([], g, for: w)
        XCTAssertEqual(t.covered, 61)
        XCTAssertEqual(t.moving, 61)
        // A still strap: constant gravity, delta 0.
        let still = (w.startSec - 12...w.endSec).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let st = tally([], still, for: w)
        XCTAssertEqual(st.covered, 61)
        XCTAssertEqual(st.moving, 0)
    }

    func testStepSampleWithoutAClassFallsBackToGravityForThatSecond() {
        let w = workout(minutes: 1)
        let s = [StepSample(ts: w.startSec, counter: 5, activityClass: nil)]
        let g = [GravitySample(ts: w.startSec - 1, x: 0, y: 0, z: 1), GravitySample(ts: w.startSec, x: 2, y: 0, z: 1)]
        let t = tally(s, g, for: w)
        XCTAssertEqual(t.covered, 1)
        XCTAssertEqual(t.moving, 1)
    }

    func testFirstSampleOfATimestampWins() {
        let w = workout(minutes: 1)
        let s = [StepSample(ts: w.startSec, counter: 0, activityClass: 0), StepSample(ts: w.startSec, counter: 0, activityClass: 2)]
        XCTAssertEqual(tally(s, for: w).moving, 0)
    }

    func testSamplesOutsideTheWindowAreIgnored() {
        let w = workout(minutes: 1)
        let s = [StepSample(ts: w.startSec - 5, counter: 0, activityClass: 2), StepSample(ts: w.endSec + 5, counter: 0, activityClass: 2)]
        XCTAssertEqual(tally(s, for: w), .init(seconds: 61, covered: 0, moving: 0))
    }

    // MARK: Settings and trace

    func testSettingsDefaultsAndSanitising() {
        let d = UserDefaults(suiteName: "AutoWorkoutMotionGateTests")!
        d.removePersistentDomain(forName: "AutoWorkoutMotionGateTests")
        XCTAssertEqual(AutoWorkoutMotionGate.Settings.load(defaults: d), .init(minMinutes: 15, requireMotion: true))
        d.set(30, forKey: AutoWorkoutMotionGate.minMinutesKey)
        d.set(false, forKey: AutoWorkoutMotionGate.requireMotionKey)
        XCTAssertEqual(AutoWorkoutMotionGate.Settings.load(defaults: d), .init(minMinutes: 30, requireMotion: false))
        d.set(7, forKey: AutoWorkoutMotionGate.minMinutesKey)
        XCTAssertEqual(AutoWorkoutMotionGate.Settings.load(defaults: d).minMinutes, 15)
    }

    func testTraceLines() {
        let e = AutoWorkoutMotionGate.Evaluation(verdict: .noMotion, durationMin: 34, movingShare: 0.123,
                                                 coverage: 1, hrMargin: 52)
        XCTAssertEqual(AutoWorkoutMotionGate.traceLine(e),
                       "autoDetect gate verdict=noMotion why=belowMovingShare dur=34min moving=12% coverage=100% hrMargin=52")
        for v: AutoWorkoutMotionGate.Verdict in [.confirmed, .tooShort, .lowIntensity, .noMotion, .motionMissing] {
            let line = AutoWorkoutMotionGate.traceLine(.init(verdict: v, durationMin: 1, movingShare: 0, coverage: 0, hrMargin: 0))
            XCTAssertTrue(line.hasPrefix("autoDetect gate verdict=\(v.rawValue) why=\(v.why) "), line)
        }
    }
}
