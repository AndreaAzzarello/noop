import XCTest
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// Limits and statistics behind the detected-workout review sheet. Pure: no store, no clock, no UI.
final class DetectedWorkoutReviewTests: XCTestCase {

    private let t0 = 1_700_000_000
    private var window: DetectedWorkout {
        // 60-minute window starting at t0.
        DetectedWorkout(startSec: t0, endSec: t0 + 3600, avgBpm: 150, peakBpm: 170, durationMin: 60)
    }
    private var farFuture: Int { t0 + 10 * 3600 }

    // MARK: bounds

    func testBoundsAddThirtyMinutesEitherSide() {
        let b = DetectedWorkoutReview.bounds(for: window, now: farFuture)
        XCTAssertEqual(b.earliest, t0 - 1800)
        XCTAssertEqual(b.latest, t0 + 3600 + 1800)
    }

    func testBoundsNeverReachIntoTheFuture() {
        let now = t0 + 3600 + 600
        XCTAssertEqual(DetectedWorkoutReview.bounds(for: window, now: now).latest, now)
    }

    // MARK: clamp

    func testClampKeepsAValidSpanUntouched() {
        let c = DetectedWorkoutReview.clamp(start: t0 + 300, end: t0 + 3000, for: window, now: farFuture)
        XCTAssertEqual(c.start, t0 + 300)
        XCTAssertEqual(c.end, t0 + 3000)
    }

    func testClampStopsStartAtEarliestAndEndAtLatest() {
        let c = DetectedWorkoutReview.clamp(start: t0 - 99_999, end: t0 + 99_999, for: window, now: farFuture)
        XCTAssertEqual(c.start, t0 - 1800)
        XCTAssertEqual(c.end, t0 + 3600 + 1800)
    }

    func testClampStopsEndAtNow() {
        let now = t0 + 3600 + 600
        let c = DetectedWorkoutReview.clamp(start: t0, end: t0 + 99_999, for: window, now: now)
        XCTAssertEqual(c.end, now)
    }

    func testClampEnforcesMinimumSpanByMovingTheEnd() {
        let c = DetectedWorkoutReview.clamp(start: t0 + 600, end: t0 + 700, for: window, now: farFuture)
        XCTAssertEqual(c.start, t0 + 600)
        XCTAssertEqual(c.end, t0 + 600 + DetectedWorkoutReview.minSpanSec)
    }

    func testClampPullsStartBackWhenTheMinimumSpanWouldPassLatest() {
        // "now" sits right at the window's end, so the latest allowed end is the window end. Start dragged
        // up against it: the end cannot move further, so the start follows it back by the minimum span.
        let now = t0 + 3600
        let b = DetectedWorkoutReview.bounds(for: window, now: now)
        XCTAssertEqual(b.latest, now)
        let c = DetectedWorkoutReview.clamp(start: b.latest, end: b.latest, for: window, now: now)
        XCTAssertEqual(c.end, now)
        XCTAssertEqual(c.start, now - DetectedWorkoutReview.minSpanSec)
    }

    func testClampKeepsTheSpanOverlappingTheDetectedWindow() {
        // A span entirely after the window is pulled back so it still overlaps it.
        let after = DetectedWorkoutReview.clamp(start: t0 + 3600 + 1700, end: t0 + 3600 + 1800, for: window, now: farFuture)
        XCTAssertLessThan(after.start, window.endSec)
        // A span entirely before it is pulled forward.
        let before = DetectedWorkoutReview.clamp(start: t0 - 1800, end: t0 - 1700, for: window, now: farFuture)
        XCTAssertGreaterThan(before.end, window.startSec)
    }

    func testClampOutputAlwaysInsideBoundsAndOverlapping() {
        let b = DetectedWorkoutReview.bounds(for: window, now: farFuture)
        for s in stride(from: t0 - 4000, through: t0 + 6000, by: 450) {
            for e in stride(from: t0 - 4000, through: t0 + 6000, by: 450) {
                let c = DetectedWorkoutReview.clamp(start: s, end: e, for: window, now: farFuture)
                XCTAssertGreaterThanOrEqual(c.start, b.earliest, "s=\(s) e=\(e)")
                XCTAssertLessThanOrEqual(c.end, b.latest, "s=\(s) e=\(e)")
                XCTAssertGreaterThanOrEqual(c.end - c.start, DetectedWorkoutReview.minSpanSec, "s=\(s) e=\(e)")
                XCTAssertLessThan(c.start, window.endSec, "s=\(s) e=\(e)")
                XCTAssertGreaterThan(c.end, window.startSec, "s=\(s) e=\(e)")
            }
        }
    }

    // MARK: stats

    /// One sample a minute: bpm = 100 + minute, from t0 to t0 + 3600 inclusive (61 samples).
    private var samples: [HRSample] {
        (0...60).map { HRSample(ts: t0 + $0 * 60, bpm: 100 + $0) }
    }

    func testStatsOverTheWholeWindowIncludeBothEdges() {
        let s = DetectedWorkoutReview.stats(samples: samples, start: t0, end: t0 + 3600)
        XCTAssertEqual(s?.durationMin, 60)
        XCTAssertEqual(s?.maxBpm, 160)
        XCTAssertEqual(s?.avgBpm, 130)   // mean of 100...160
    }

    func testStatsRecomputeWhenTheWindowIsNarrowed() {
        // Minutes 10...20 inclusive: bpm 110...120, mean 115, 10 whole minutes.
        let s = DetectedWorkoutReview.stats(samples: samples, start: t0 + 600, end: t0 + 1200)
        XCTAssertEqual(s?.durationMin, 10)
        XCTAssertEqual(s?.avgBpm, 115)
        XCTAssertEqual(s?.maxBpm, 120)
    }

    func testStatsRoundTheMeanLikeTheDetector() {
        let pair = [HRSample(ts: t0, bpm: 100), HRSample(ts: t0 + 60, bpm: 101)]   // mean 100.5 → 101
        XCTAssertEqual(DetectedWorkoutReview.stats(samples: pair, start: t0, end: t0 + 60)?.avgBpm, 101)
    }

    func testStatsFloorTheDurationToWholeMinutes() {
        let s = DetectedWorkoutReview.stats(samples: samples, start: t0, end: t0 + 119)
        XCTAssertEqual(s?.durationMin, 1)
    }

    func testStatsAreNilWithFewerThanTwoSamplesInTheWindow() {
        XCTAssertNil(DetectedWorkoutReview.stats(samples: [], start: t0, end: t0 + 600))
        XCTAssertNil(DetectedWorkoutReview.stats(samples: samples, start: t0 + 10, end: t0 + 50))   // none inside
        XCTAssertNil(DetectedWorkoutReview.stats(samples: samples, start: t0 + 50, end: t0 + 70))   // one inside
    }
}
