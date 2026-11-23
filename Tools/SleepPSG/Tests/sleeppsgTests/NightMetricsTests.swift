import XCTest
@testable import SleepRecipe

/// Hand-built hypnograms with known answers. All synthetic.
final class NightMetricsTests: XCTestCase {

    private func run(_ stage: String, _ minutes: Double) -> [String] {
        [String](repeating: stage, count: Int(minutes * 2))
    }

    /// 10 min wake, then a 275-min sleep period: 60 light, 30 deep, 60 light, 20 REM, 5 wake, 60 light, 40 REM.
    /// Deep sits wholly before the period midpoint (137.5 min) and both REM runs wholly after it.
    private var night: [String] {
        run("wake", 10) + run("light", 60) + run("deep", 30) + run("light", 60) + run("rem", 20)
            + run("wake", 5) + run("light", 60) + run("rem", 40)
    }

    func testTotalsAndShares() {
        let m = NightMetrics.of(night)
        XCTAssertTrue(m.hasSleep)
        XCTAssertEqual(m.latencyMin, 10, accuracy: 1e-9)
        XCTAssertEqual(m.tstMin, 270, accuracy: 1e-9)            // 60+30+60+20+60+40
        XCTAssertEqual(m.wasoMin, 5, accuracy: 1e-9)
        XCTAssertEqual(m.lightPct, 100.0 * 180 / 270, accuracy: 1e-9)
        XCTAssertEqual(m.deepPct, 100.0 * 30 / 270, accuracy: 1e-9)
        XCTAssertEqual(m.remPct, 100.0 * 60 / 270, accuracy: 1e-9)
        XCTAssertEqual(m.wasoPctOfPeriod, 100.0 * 5 / 275, accuracy: 1e-9)
    }

    func testHalvesAndLatencies() {
        let m = NightMetrics.of(night)
        XCTAssertEqual(m.deepFirstHalf ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(m.remSecondHalf ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(m.firstRemLatencyMin ?? -1, 150, accuracy: 1e-9)   // 60 light + 30 deep + 60 light
    }

    func testBoutsTransitionsAndAwakenings() {
        let m = NightMetrics.of(night)
        // Bouts in the period: light, deep, light, rem, wake, light, rem = 7 bouts, 6 changes, over 275 min.
        XCTAssertEqual(m.transitionsPerHour, 6.0 / (275.0 / 60.0), accuracy: 1e-9)
        XCTAssertEqual(m.shortBoutShare, 0, accuracy: 1e-9)               // the 5-min wake is >= 3 min
        XCTAssertEqual(m.awakenings, 1)
        XCTAssertEqual(m.medianBoutMin, 40, accuracy: 1e-9)              // sorted 5,20,30,40,60,60,60 min
    }

    func testRemPeriodsMergeAcrossShortGapsAndSpacingIsMedianOnsetToOnset() {
        // Onset at 0 (no leading wake). REM starts at 100, 190 (a 3-min wake gap sits inside it) and 280 min.
        let labels = run("light", 100) + run("rem", 20) + run("light", 70)
            + run("rem", 10) + run("wake", 3) + run("rem", 10) + run("light", 67) + run("rem", 20)
        let m = NightMetrics.of(labels)
        XCTAssertEqual(m.remPeriods, 3)                                   // the 3-min gap is merged
        XCTAssertEqual(m.remPeriodMin ?? -1, 90, accuracy: 1e-9)          // 100 -> 190 -> 280
    }

    func testAShortFlickerCountsAsShortBoutsAndIsNotAnAwakening() {
        let labels = run("light", 30) + ["wake", "light", "wake", "light", "wake", "light"] + run("light", 30)
        let m = NightMetrics.of(labels)
        XCTAssertEqual(m.awakenings, 0)
        XCTAssertGreaterThan(m.shortBoutShare, 0.5)
    }

    func testNoSustainedSleepReportsHasSleepFalse() {
        XCTAssertFalse(NightMetrics.of(run("wake", 60)).hasSleep)
        XCTAssertFalse(NightMetrics.of(run("light", 4)).hasSleep)         // 4 min < the 5-min onset run
        XCTAssertFalse(NightMetrics.of([]).hasSleep)
    }

    func testTrailingWakeIsOutsideTheSleepPeriod() {
        let m = NightMetrics.of(run("light", 60) + run("wake", 30))
        XCTAssertEqual(m.wasoMin, 0, accuracy: 1e-9)
        XCTAssertEqual(m.tstMin, 60, accuracy: 1e-9)
    }

    // MARK: Bands

    func testBandsScoreOnlyTheMetricsBothSidesKnow() {
        let bands = PlausibilityBands(source: "test", ranges: ["deepPct": 10...20, "remPct": 30...40])
        let m = NightMetrics.of(night)                                    // deep 11.1 %, rem 22.2 %
        let s = bands.score(m)
        XCTAssertEqual(s.judged, 2)
        XCTAssertEqual(s.inside, 1)
        XCTAssertNil(bands.contains("lightPct", m.lightPct))
        XCTAssertNil(bands.contains("deepPct", nil))
    }

    func testBandsRoundTripThroughJSON() throws {
        let back = try PlausibilityBands.parse(json: try PlausibilityBands.broad.encoded())
        XCTAssertEqual(back, PlausibilityBands.broad)
    }

    func testBandsParseIgnoresMalformedRanges() throws {
        let json = Data(#"{"source":"x","ranges":{"deepPct":[5,10],"remPct":[9,1],"lightPct":[1]}}"#.utf8)
        let b = try PlausibilityBands.parse(json: json)
        XCTAssertEqual(Set(b.ranges.keys), ["deepPct"])
    }
}
