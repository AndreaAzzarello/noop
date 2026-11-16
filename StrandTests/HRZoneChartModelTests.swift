import XCTest
import StrandAnalytics
import StrandDesign
@testable import Strand

/// Pins the pure half of the zone-coloured workout HR curve: which zone a reading is in, and where the
/// series is split so a coloured run never crosses a threshold.
final class HRZoneChartModelTests: XCTestCase {

    /// HRmax 200 → lower bounds 100 / 120 / 140 / 160 / 180 (Z1…Z5).
    private let zones = HRZones.zones(maxHR: 200, source: "manual")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func pt(_ minute: Double, _ bpm: Double, segment: String = "default") -> TrendPoint {
        TrendPoint(date: t0.addingTimeInterval(minute * 60), value: bpm, segment: segment)
    }

    func testZoneAtBoundaries() {
        XCTAssertEqual(zones.zoneNumber(forBPM: 99.9), 0)
        XCTAssertEqual(zones.zoneNumber(forBPM: 100), 1)
        XCTAssertEqual(zones.zoneNumber(forBPM: 119.9), 1)
        XCTAssertEqual(zones.zoneNumber(forBPM: 120), 2)
        XCTAssertEqual(zones.zoneNumber(forBPM: 200), 5)
    }

    func testSingleZoneIsOneRun() {
        let runs = HRZoneChartModel.runs([pt(0, 125), pt(1, 130), pt(2, 135)], zoneSet: zones)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].zone, 2)
        XCTAssertEqual(runs[0].points.count, 3)
    }

    func testCrossingOneThresholdSplitsAtTheInterpolatedPoint() {
        // 110 (Z1) → 130 (Z2) over two minutes crosses 120 exactly halfway.
        let runs = HRZoneChartModel.runs([pt(0, 110), pt(2, 130)], zoneSet: zones)
        XCTAssertEqual(runs.map(\.zone), [1, 2])
        let boundary = runs[0].points.last!
        XCTAssertEqual(boundary.value, 120, accuracy: 1e-9)
        XCTAssertEqual(boundary.date.timeIntervalSince(t0), 60, accuracy: 1e-6)
        XCTAssertEqual(runs[1].points.first!.date, boundary.date)
        XCTAssertEqual(runs[1].points.last!.value, 130, accuracy: 1e-9)
    }

    func testJumpAcrossSeveralZonesCrossesEveryThreshold() {
        // 90 (below Z1) → 170 (Z4): crosses 100, 120, 140, 160.
        let runs = HRZoneChartModel.runs([pt(0, 90), pt(8, 170)], zoneSet: zones)
        XCTAssertEqual(runs.map(\.zone), [0, 1, 2, 3, 4])
        let boundaries = runs.dropLast().map { $0.points.last!.value }
        XCTAssertEqual(boundaries, [100, 120, 140, 160])
        let minutes = runs.dropLast().map { $0.points.last!.date.timeIntervalSince(t0) / 60 }
        for (m, expected) in zip(minutes, [1.0, 3.0, 5.0, 7.0]) { XCTAssertEqual(m, expected, accuracy: 1e-6) }
    }

    func testDescendingCrossesThresholdsInOrder() {
        let runs = HRZoneChartModel.runs([pt(0, 150), pt(2, 110)], zoneSet: zones)
        XCTAssertEqual(runs.map(\.zone), [3, 2, 1])
        XCTAssertEqual(runs.dropLast().map { $0.points.last!.value }, [140, 120])
    }

    func testReadingExactlyOnAThresholdDoesNotDuplicateAPoint() {
        let runs = HRZoneChartModel.runs([pt(0, 110), pt(1, 120), pt(2, 125)], zoneSet: zones)
        XCTAssertEqual(runs.map(\.zone), [1, 2])
        XCTAssertEqual(runs[0].points.count, 2)
        XCTAssertEqual(runs[1].points.count, 2)
        XCTAssertEqual(runs[1].points.first!.date, runs[0].points.last!.date)
    }

    func testSegmentChangeIsAGapNotAnInterpolation() {
        let runs = HRZoneChartModel.runs(
            [pt(0, 110, segment: "0"), pt(1, 112, segment: "0"), pt(10, 150, segment: "1")], zoneSet: zones)
        XCTAssertEqual(runs.map(\.zone), [1, 3])
        XCTAssertEqual(runs[0].points.count, 2)
        XCTAssertEqual(runs[1].points.map(\.value), [150])
    }

    func testUnsortedInputIsOrderedAndEmptyIsEmpty() {
        let runs = HRZoneChartModel.runs([pt(2, 130), pt(0, 110)], zoneSet: zones)
        XCTAssertEqual(runs.map(\.zone), [1, 2])
        XCTAssertTrue(HRZoneChartModel.runs([], zoneSet: zones).isEmpty)
    }

    func testCustomBoundsAreUsed() {
        let custom = HRZones.zones(maxHR: 200, customLowerBounds: [90, 110, 130, 150, 170])
        let runs = HRZoneChartModel.runs([pt(0, 100), pt(2, 120)], zoneSet: custom)
        XCTAssertEqual(runs.map(\.zone), [1, 2])
        XCTAssertEqual(runs[0].points.last!.value, 110, accuracy: 1e-9)
    }

    func testThresholdsAreStrictlyInsideTheDomainAndLabelRoundsUp() {
        let inDomain = HRZoneChartModel.thresholds(zones, in: 100...160)
        XCTAssertEqual(inDomain.map(\.zone), [2, 3])
        let fractional = HRZones.zones(maxHR: 187, source: "manual")   // Z1 lower = 93.5
        let t = HRZoneChartModel.thresholds(fractional, in: 80...200).first!
        XCTAssertEqual(t.value, 93.5, accuracy: 1e-9)
        XCTAssertEqual(t.label, 94)
    }

    func testUsableZoneSetRejectsBadInput() {
        XCTAssertNotNil(HRZoneChartModel.usableZoneSet(zones))
        XCTAssertNil(HRZoneChartModel.usableZoneSet(HRZones.zones(maxHR: 0, source: "manual")))
        let flat = HRZoneSet(zones: (1...5).map {
            HRZone(number: $0, lower: 100, upper: 100, lowerPct: 0.5, upperPct: 0.5)
        }, maxHR: 200, source: "custom")
        XCTAssertNil(HRZoneChartModel.usableZoneSet(flat))
    }

    func testNearestPicksClosestAndEarlierOnTie() {
        let pts = [pt(0, 100), pt(2, 110), pt(4, 120)]
        XCTAssertEqual(HRZoneChartModel.nearest(to: t0.addingTimeInterval(100), in: pts)?.value, 110)
        XCTAssertEqual(HRZoneChartModel.nearest(to: t0.addingTimeInterval(60), in: pts)?.value, 100)
        XCTAssertEqual(HRZoneChartModel.nearest(to: t0.addingTimeInterval(-500), in: pts)?.value, 100)
        XCTAssertNil(HRZoneChartModel.nearest(to: t0, in: []))
    }

    // MARK: paddedDomain

    func testPaddedDomainLeavesRoomAboveARuleNearTheTop() {
        // Thresholds 100/120/140/160/180. 160 sits 1 bpm under the top: margin = max(4, 6% of 61) = 4.
        let padded = HRZoneChartModel.paddedDomain(100.5...161.5, zoneSet: zones)
        XCTAssertEqual(padded.lowerBound, 100.5)
        XCTAssertGreaterThanOrEqual(padded.upperBound, 160 + 4)
        XCTAssertTrue(HRZoneChartModel.thresholds(zones, in: padded).map(\.zone).contains(4))
    }

    func testPaddedDomainIsUnchangedWhenNoRuleIsNearTheTop() {
        XCTAssertEqual(HRZoneChartModel.paddedDomain(60...150, zoneSet: zones), 60...150)
        // A rule exactly one margin below the top is not in the margin.
        XCTAssertEqual(HRZoneChartModel.paddedDomain(90...144, zoneSet: zones), 90...144)
    }

    func testPaddedDomainRepeatsWhenTheRaisedTopReachesTheNextRule() {
        // Custom rules 150 and 153: raising the top over 150 brings 153 into the margin, so it is cleared too.
        let close = HRZones.zones(maxHR: 200, customLowerBounds: [90, 110, 130, 150, 153])
        let padded = HRZoneChartModel.paddedDomain(100...151, zoneSet: close)
        XCTAssertGreaterThanOrEqual(padded.upperBound, 153 + 4)
    }

    func testPaddedDomainIgnoresRulesOutsideTheDomainAndDegenerateRanges() {
        XCTAssertEqual(HRZoneChartModel.paddedDomain(60...90, zoneSet: zones), 60...90)
        XCTAssertEqual(HRZoneChartModel.paddedDomain(120...120, zoneSet: zones), 120...120)
        // A rule at or below the lower bound never moves the top.
        XCTAssertEqual(HRZoneChartModel.paddedDomain(120...150, zoneSet: zones).lowerBound, 120)
    }
}
