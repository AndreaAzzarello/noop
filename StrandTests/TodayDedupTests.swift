import XCTest
import WhoopStore
@testable import Strand

final class TodayDedupTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }
    private var now: Date { cal.date(from: DateComponents(year: 2025, month: 8, day: 24, hour: 12))! }
    private func ts(day: Int, hour: Int) -> Int {
        Int(cal.date(from: DateComponents(year: 2025, month: 8, day: day, hour: hour))!.timeIntervalSince1970)
    }
    private func row(_ start: Int) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 1_800, sport: "Running", source: "manual",
                   durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    // MARK: Key metrics

    func testRingScoresDropWhileTheRingsAreVisibleAndKeepTheRestInOrder() {
        let out = TodayDedup.keyMetrics(KeyMetric.defaultOrder, heroVisible: true, hasBloodOxygenValue: true)
        XCTAssertEqual(out, [.hrv, .restingHr, .bloodOxygen, .respiratory, .steps, .weight, .calories])
    }

    func testRingScoresReturnWhenTheRingsAreHidden() {
        let out = TodayDedup.keyMetrics(KeyMetric.defaultOrder, heroVisible: false, hasBloodOxygenValue: true)
        XCTAssertEqual(out, KeyMetric.defaultOrder)
    }

    func testBloodOxygenWithNothingToSayIsDropped() {
        let out = TodayDedup.keyMetrics([.hrv, .bloodOxygen, .steps], heroVisible: false, hasBloodOxygenValue: false)
        XCTAssertEqual(out, [.hrv, .steps])
    }

    func testAnEmptySelectionStaysEmpty() {
        XCTAssertEqual(TodayDedup.keyMetrics([], heroVisible: true, hasBloodOxygenValue: false), [])
    }

    // MARK: Recovery vitals

    func testVitalsCardIsDroppedOnlyWhenTheGridCarriesAllThree() {
        XCTAssertFalse(TodayDedup.showsRecoveryVitals(keyMetricsVisible: true, shownKeyMetrics: [.hrv, .restingHr, .respiratory, .steps]))
        XCTAssertTrue(TodayDedup.showsRecoveryVitals(keyMetricsVisible: true, shownKeyMetrics: [.hrv, .restingHr, .steps]))
        XCTAssertTrue(TodayDedup.showsRecoveryVitals(keyMetricsVisible: true, shownKeyMetrics: []))
    }

    func testVitalsCardStaysWhenTheGridIsHidden() {
        XCTAssertTrue(TodayDedup.showsRecoveryVitals(keyMetricsVisible: false, shownKeyMetrics: [.hrv, .restingHr, .respiratory]))
    }

    // MARK: Workouts

    func testLastWorkoutsHidesOnlyWhileTodaysWorkoutIsShownAbove() {
        XCTAssertFalse(TodayDedup.showsLastWorkouts(todaysWorkoutShownAbove: true))
        XCTAssertTrue(TodayDedup.showsLastWorkouts(todaysWorkoutShownAbove: false))
    }

    func testRecentListDropsTodaysWorkoutsOnlyWhileViewingToday() {
        let today = row(ts(day: 24, hour: 8)), yesterday = row(ts(day: 23, hour: 8))
        let rows = [today, yesterday]
        XCTAssertEqual(TodayDedup.excludingToday(rows, isViewingToday: true, now: now, calendar: cal).map(\.startTs),
                       [yesterday.startTs])
        XCTAssertEqual(TodayDedup.excludingToday(rows, isViewingToday: false, now: now, calendar: cal).map(\.startTs),
                       [today.startTs, yesterday.startTs])
    }

    func testAWorkoutTheCardDoesNotShowStaysInTheList() {
        let later = row(ts(day: 24, hour: 15))   // starts after `now`: the card ignores it, so the list keeps it
        XCTAssertEqual(TodayDedup.excludingToday([later], isViewingToday: true, now: now, calendar: cal).count, 1)
    }

    // MARK: Heart-rate chart

    func testChartMarkersOnlyWhenTheRingsAreHidden() {
        XCTAssertFalse(TodayDedup.showsHRChartMarkers(heroVisible: true))
        XCTAssertTrue(TodayDedup.showsHRChartMarkers(heroVisible: false))
    }
}
