import XCTest
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// Pins the edge trim of an auto-detected workout. All data is synthetic: a reading every 10 s in blocks of
/// constant bpm, so every expected cut can be worked out by hand.
final class AutoWorkoutEdgeTrimTests: XCTestCase {

    private let t0 = 1_800_000_000
    /// Zone 1 starts at 96 bpm (HRmax 191), resting 55: the threshold is 96.
    private let threshold = 96

    /// Builds readings from consecutive (minutes, bpm) blocks; a nil bpm is a hole with no readings.
    private func series(_ blocks: [(min: Int, bpm: Int?)]) -> (samples: [HRSample], start: Int, end: Int) {
        var out: [HRSample] = []
        var ts = t0
        for b in blocks {
            for _ in 0..<(b.min * 6) {
                if let bpm = b.bpm { out.append(HRSample(ts: ts, bpm: bpm)) }
                ts += 10
            }
        }
        return (out, out.first!.ts, out.last!.ts)
    }

    private func trim(_ s: (samples: [HRSample], start: Int, end: Int), minMinutes: Int = 15) -> AutoWorkoutEdgeTrim.Result {
        AutoWorkoutEdgeTrim.trim(samples: s.samples, start: s.start, end: s.end,
                                 threshold: threshold, basis: "zone1", minMinutes: minMinutes)
    }

    // MARK: Trim

    func testWarmUpAndCoolDownAreTrimmedAndTheCentreIsKept() {
        let s = series([(25, 90), (120, 130), (10, 85)])
        let r = trim(s)
        XCTAssertEqual(r.outcome, .trimmed)
        // The 3-minute smoothing lets the minute next to the effort count, so the cut is at most a minute early.
        XCTAssertEqual(r.headSec, 24 * 60)
        XCTAssertTrue((500...600).contains(r.tailSec), "tail \(r.tailSec)")
        XCTAssertEqual(r.startSec, s.start + r.headSec)
        XCTAssertEqual(r.endSec, s.end - r.tailSec)
        // Never cut into the 120 min of effort.
        XCTAssertLessThanOrEqual(r.startSec - s.start, 25 * 60)
        XCTAssertGreaterThanOrEqual(r.endSec - s.start, (25 + 120) * 60)
    }

    func testEachSideIsCappedAtThirtyMinutes() {
        let s = series([(45, 80), (100, 130), (5, 80)])
        let r = trim(s)
        XCTAssertEqual(r.outcome, .capped)
        XCTAssertEqual(r.headSec, AutoWorkoutEdgeTrim.maxTrimPerSideSec)
        XCTAssertLessThan(r.tailSec, AutoWorkoutEdgeTrim.maxTrimPerSideSec)
    }

    func testADipInTheMiddleIsNeverCut() {
        let s = series([(10, 80), (40, 130), (8, 80), (40, 130)])
        let r = trim(s)
        XCTAssertEqual(r.outcome, .trimmed)
        XCTAssertEqual(r.endSec, s.end, "tail untouched")
        XCTAssertTrue((540...600).contains(r.headSec), "head \(r.headSec)")
    }

    func testAShortEarlySpikeIsNotStableEffort() {
        // A 2-minute spike at minute 5 would pull the start to ~4 min if a blip counted.
        let s = series([(5, 80), (2, 140), (13, 80), (60, 130)])
        let r = trim(s)
        XCTAssertEqual(r.headSec, 19 * 60)
    }

    func testAHoleInTheDataDoesNotCutTheEffortAroundIt() {
        let s = series([(15, 80), (20, 130), (3, nil), (20, 130)])
        let r = trim(s)
        XCTAssertEqual(r.outcome, .trimmed)
        XCTAssertEqual(r.endSec, s.end)
        XCTAssertTrue((780...900).contains(r.headSec), "head \(r.headSec)")
    }

    func testConstantEffortIsLeftAlone() {
        let s = series([(60, 130)])
        let r = trim(s)
        XCTAssertEqual(r.outcome, .unchanged)
        XCTAssertEqual(r.startSec, s.start)
        XCTAssertEqual(r.endSec, s.end)
        XCTAssertEqual(r.headSec, 0)
        XCTAssertEqual(r.tailSec, 0)
    }

    func testNeverStableEffortIsLeftAsDetected() {
        let s = series([(30, 90)])
        let r = trim(s)
        XCTAssertEqual(r.outcome, .noStableRun)
        XCTAssertEqual(r.startSec, s.start)
        XCTAssertEqual(r.endSec, s.end)
    }

    func testTrimThatWouldFallBelowTheMinimumDurationIsRefused() {
        let s = series([(10, 80), (20, 130)])
        let r = trim(s, minMinutes: 30)
        XCTAssertEqual(r.outcome, .tooShort)
        XCTAssertEqual(r.startSec, s.start)
        XCTAssertEqual(r.endSec, s.end)
    }

    func testTrimThatWouldRemoveMoreThanHalfIsRefused() {
        let s = series([(30, 80), (30, 130), (30, 80)])
        let r = trim(s, minMinutes: 15)
        XCTAssertEqual(r.outcome, .tooShort)
        XCTAssertEqual(r.headSec, 0)
        XCTAssertEqual(r.tailSec, 0)
    }

    func testSamplesOutsideTheWindowAreIgnoredAndOrderDoesNotMatter() {
        let s = series([(25, 90), (60, 130), (10, 85)])
        let a = trim(s)
        let shuffled = (s.samples + [HRSample(ts: s.start - 600, bpm: 200), HRSample(ts: s.end + 600, bpm: 200)])
            .reversed()
        let b = AutoWorkoutEdgeTrim.trim(samples: Array(shuffled), start: s.start, end: s.end,
                                         threshold: threshold, basis: "zone1", minMinutes: 15)
        XCTAssertEqual(a, b)
    }

    // MARK: Threshold

    func testThresholdIsZoneOneStartButNeverBelowTheDetectorFloor() {
        XCTAssertEqual(AutoWorkoutEdgeTrim.threshold(restingBpm: 55, zone1Lower: 95.5).bpm, 96)
        XCTAssertEqual(AutoWorkoutEdgeTrim.threshold(restingBpm: 55, zone1Lower: 95.5).basis, "zone1")
        // Resting 70 puts the detector floor at 100, above the Zone 1 start.
        XCTAssertEqual(AutoWorkoutEdgeTrim.threshold(restingBpm: 70, zone1Lower: 95.5).bpm, 100)
        // No resting value: the detector's default of 60 applies.
        XCTAssertEqual(AutoWorkoutEdgeTrim.threshold(restingBpm: nil, zone1Lower: 80).bpm, 90)
    }

    func testThresholdFallsBackToRestingPlusGateMarginWithoutZones() {
        let t = AutoWorkoutEdgeTrim.threshold(restingBpm: 55, zone1Lower: nil)
        XCTAssertEqual(t.bpm, 55 + AutoWorkoutMotionGate.intensityMarginBPM)
        XCTAssertEqual(t.basis, "restingMargin")
        XCTAssertEqual(AutoWorkoutEdgeTrim.threshold(restingBpm: nil, zone1Lower: nil).bpm,
                       AutoWorkoutDetector.defaultRestingHR + AutoWorkoutMotionGate.intensityMarginBPM)
    }

    func testZoneOneLowerAgreesWithTheChartLegend() {
        // The cut and the legend's "Below Zone 1" are the same number.
        let lower = AutoWorkoutEdgeTrim.zone1Lower(hrMax: 191, customLowerBounds: nil)
        XCTAssertEqual(AutoWorkoutEdgeTrim.threshold(restingBpm: 55, zone1Lower: lower).bpm, 96)
        let set = HRZones.zones(maxHR: 191, source: "manual")
        XCTAssertEqual(HRZoneChartModel.range(forZone: 0, in: set), .below(96))
    }

    func testZoneOneLowerFollowsCustomBoundsAndRejectsNoHRMax() {
        XCTAssertEqual(AutoWorkoutEdgeTrim.zone1Lower(hrMax: 191, customLowerBounds: [100, 120, 140, 160, 180]), 100)
        // Invalid custom bounds fall back to the conventional model, as `HRZones` does.
        XCTAssertEqual(AutoWorkoutEdgeTrim.zone1Lower(hrMax: 191, customLowerBounds: [100, 100])!, 95.5, accuracy: 1e-9)
        XCTAssertNil(AutoWorkoutEdgeTrim.zone1Lower(hrMax: nil, customLowerBounds: nil))
        XCTAssertNil(AutoWorkoutEdgeTrim.zone1Lower(hrMax: 0, customLowerBounds: nil))
    }

    func testStoredCustomBoundsAreReadAndValidated() throws {
        let suite = "AutoWorkoutEdgeTrimTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(AutoWorkoutEdgeTrim.storedCustomLowerBounds(defaults: defaults))
        defaults.set("100,120,140,160,180", forKey: AutoWorkoutEdgeTrim.customZonesKey)
        XCTAssertEqual(AutoWorkoutEdgeTrim.storedCustomLowerBounds(defaults: defaults), [100, 120, 140, 160, 180])
        defaults.set("100,100,140,160,180", forKey: AutoWorkoutEdgeTrim.customZonesKey)
        XCTAssertNil(AutoWorkoutEdgeTrim.storedCustomLowerBounds(defaults: defaults))
    }

    /// Pins the literal key against the one `ProfileStore` really writes.
    @MainActor
    func testCustomZonesKeyMatchesWhatProfileStoreWrites() {
        let key = AutoWorkoutEdgeTrim.customZonesKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let store = ProfileStore()
        store.hrZoneThresholds = [101, 121, 141, 161, 181]
        XCTAssertEqual(AutoWorkoutEdgeTrim.storedCustomLowerBounds(), [101, 121, 141, 161, 181])
    }

    // MARK: Trace

    func testTraceLineCarriesOnlyWholeMinutesAndReasons() {
        let r = AutoWorkoutEdgeTrim.Result(startSec: 1_800_001_500, endSec: 1_800_009_000, headSec: 1500,
                                           tailSec: 500, outcome: .trimmed, basis: "zone1")
        XCTAssertEqual(AutoWorkoutEdgeTrim.traceLine(r),
                       "autoDetect trim headMin=25 tailMin=8 basis=zone1 result=trimmed")
    }
}
