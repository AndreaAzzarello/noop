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

    func testRingScoresNeverReachTheGridAndTheGridIsCompletedToEight() {
        let out = TodayDedup.keyMetrics(KeyMetric.defaultOrder)
        XCTAssertEqual(out, [.hrv, .restingHr, .bloodOxygen, .respiratory, .steps, .weight, .calories, .skinTemp])
    }

    func testBloodOxygenWithNothingToSayStaysSoTheGridKeepsItsBalance() {
        let out = TodayDedup.keyMetrics([.hrv, .bloodOxygen, .steps, .weight, .calories, .skinTemp])
        XCTAssertEqual(out, [.hrv, .bloodOxygen, .steps, .weight, .calories, .skinTemp])
    }

    func testAnEmptySelectionIsCompletedToSix() {
        XCTAssertEqual(TodayDedup.keyMetrics([]), [.hrv, .restingHr, .bloodOxygen, .respiratory, .steps, .weight])
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

    func testRecentListDropsTheWorkoutsOfTheShownDay() {
        let today = row(ts(day: 24, hour: 8)), yesterday = row(ts(day: 23, hour: 8))
        let rows = [today, yesterday]
        XCTAssertEqual(TodayDedup.excludingShown(rows, day: now, now: now, calendar: cal).map(\.startTs),
                       [yesterday.startTs])
        // Browsing yesterday: the card shows yesterday's workout, so the list drops that one and keeps today's.
        XCTAssertEqual(TodayDedup.excludingShown(rows, day: Date(timeIntervalSince1970: TimeInterval(yesterday.startTs)),
                                                 now: now, calendar: cal).map(\.startTs),
                       [today.startTs])
    }

    func testAWorkoutTheCardDoesNotShowStaysInTheList() {
        let later = row(ts(day: 24, hour: 15))   // starts after `now`: the card ignores it, so the list keeps it
        XCTAssertEqual(TodayDedup.excludingShown([later], day: now, now: now, calendar: cal).count, 1)
    }

    // MARK: Heart-rate chart

    func testChartMarkersOnlyWhenTheRingsAreHidden() {
        XCTAssertFalse(TodayDedup.showsHRChartMarkers(heroVisible: true))
        XCTAssertTrue(TodayDedup.showsHRChartMarkers(heroVisible: false))
    }
}
