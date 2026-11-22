import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
import StrandDesign
@testable import Strand

/// The quick edit of a LONG, auto-detected workout that was saved and reopened: 99 minutes of 1 Hz heart rate with a
/// mean of 117 bpm (right at the Zone 1/2 edge), a ±30 min slack on both sides, duplicated and out-of-order readings.
final class WorkoutQuickEditLongWorkoutTests: XCTestCase {

    private let start = 1_763_742_000            // arbitrary fixed instant
    private var end: Int { start + 99 * 60 }

    /// Deterministic noisy series around `mean`, one reading per second over `[from, to]`.
    private func series(from: Int, to: Int, mean: Double = 117) -> [HRSample] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int((seed >> 33) % 7)) - 3        // -3...+3
        }
        return (from...to).map { ts in
            let slow = 9 * sin(Double(ts - from) / 45)
            return HRSample(ts: ts, bpm: Int((mean + slow + noise()).rounded()))
        }
    }

    /// The same series with every 7th reading repeated (another bpm) and reversed in chunks of 500.
    private func messy(_ samples: [HRSample]) -> [HRSample] {
        var out: [HRSample] = []
        for (i, s) in samples.enumerated() {
            out.append(s)
            if i % 7 == 0 { out.append(HRSample(ts: s.ts, bpm: s.bpm + 5)) }
        }
        return stride(from: 0, to: out.count, by: 500).flatMap { Array(out[$0..<min($0 + 500, out.count)].reversed()) }
    }

    private func savedRow() -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: "Karate", source: "auto", durationS: 99 * 60,
                   energyKcal: nil, avgHr: 117, maxHr: 150, strain: nil, distanceM: nil,
                   zonesJSON: nil, notes: nil, steps: nil)
    }

    private func zones() -> HRZoneSet { HRZones.zones(maxHR: 190) }

    private func points(_ samples: [HRSample]) -> [TrendPoint] {
        samples.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: Double($0.bpm)) }
    }

    func testReviewMathSurvivesLongMessyWindow() {
        let row = savedRow()
        let window = DetectedWorkout(startSec: row.startTs, endSec: row.endTs, avgBpm: 117, peakBpm: 150, durationMin: 99)
        let b = DetectedWorkoutReview.bounds(for: window, now: end + 3 * 3600)
        let samples = messy(series(from: b.earliest, to: b.latest))
        XCTAssertNotNil(DetectedWorkoutReview.stats(samples: samples, start: start, end: end))
        XCTAssertNotNil(WorkoutQuickEdit.avgHr(row: row, start: start + 60, end: end - 60, samples: samples))
        XCTAssertNotNil(WorkoutQuickEdit.rebuilt(row: row, start: Date(timeIntervalSince1970: TimeInterval(start)),
                                                 end: Date(timeIntervalSince1970: TimeInterval(end)), sport: "Karate",
                                                 samples: samples, now: Date(timeIntervalSince1970: TimeInterval(end + 3600))))
    }

    /// The chart is handed a bounded number of runs (series) for a long, noisy, messy 1 Hz workout.
    func testZoneRunsAreBoundedForLongNoisyWorkout() {
        let samples = messy(series(from: start - 1800, to: end + 1800))
        let sorted = points(samples).sorted { $0.date < $1.date }
        let result = HRZoneChartModel.drawn(sorted, zoneSet: zones())
        let marks = result.runs.reduce(0) { $0 + $1.points.count }
        XCTAssertLessThanOrEqual(result.runs.count, HRZoneChartModel.maxRuns, "runs=\(result.runs.count) marks=\(marks)")
        XCTAssertGreaterThanOrEqual(result.runs.count, 1)
        // Dates strictly increase, so the chart's identity by date stays unique.
        XCTAssertEqual(result.points.map(\.date), result.points.map(\.date).sorted())
        XCTAssertEqual(Set(result.points.map(\.date)).count, result.points.count)
        // The coarser series still spans the whole window.
        XCTAssertEqual(result.points.first?.date, sorted.first?.date)
        XCTAssertEqual(result.points.last?.date, sorted.last?.date)
    }

    /// A series that does not flicker keeps the usual min/max picture (no coarsening).
    func testSteadyWorkoutKeepsFullDownsample() {
        let steady = (0..<6000).map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(start + $0)),
                                                  value: 140 + Double($0 % 5)) }
        let result = HRZoneChartModel.drawn(steady, zoneSet: zones())
        XCTAssertEqual(result.runs.count, 1)
        XCTAssertGreaterThan(result.points.count, 100)
    }

    func testMeanBucketingEdgeCases() {
        let few = (0..<5).map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0)), value: Double($0)) }
        XCTAssertEqual(HRZoneChartModel.meanBucketed(few, targetCount: 12).count, 5)   // already small: unchanged
        XCTAssertEqual(HRZoneChartModel.meanBucketed([], targetCount: 12).count, 0)
        let many = (0..<1000).map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0)), value: 100) }
        let out = HRZoneChartModel.meanBucketed(many, targetCount: 12)
        XCTAssertLessThanOrEqual(out.count, 12)
        XCTAssertEqual(out.first?.date, many.first?.date)
        XCTAssertEqual(out.last?.date, many.last?.date)
    }
}
