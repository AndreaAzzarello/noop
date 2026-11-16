import XCTest
import WhoopStore
@testable import Strand

final class TodayWorkoutSummaryTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }

    /// 2025-08-24 12:00 in Rome.
    private var now: Date {
        cal.date(from: DateComponents(year: 2025, month: 8, day: 24, hour: 12))!
    }

    private func ts(day: Int, hour: Int, minute: Int = 0, second: Int = 0) -> Int {
        Int(cal.date(from: DateComponents(year: 2025, month: 8, day: day, hour: hour,
                                          minute: minute, second: second))!.timeIntervalSince1970)
    }

    private func row(_ start: Int, zones: String? = nil, durationS: Double? = 1_800) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 1_800, sport: "Running", source: "manual",
                   durationS: durationS, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                   distanceM: nil, zonesJSON: zones, notes: nil, steps: nil)
    }

    // MARK: selection

    func testKeepsTodayAndDropsYesterdayAtMidnight() {
        let midnight = row(ts(day: 24, hour: 0))
        let lastSecond = row(ts(day: 23, hour: 23, minute: 59, second: 59))
        let kept = TodayWorkoutSummary.todaysWorkouts([lastSecond, midnight], now: now, calendar: cal)
        XCTAssertEqual(kept.map(\.startTs), [midnight.startTs])
    }

    func testDropsAWorkoutStartingAfterNow() {
        let later = row(ts(day: 24, hour: 15))
        XCTAssertTrue(TodayWorkoutSummary.todaysWorkouts([later], now: now, calendar: cal).isEmpty)
    }

    func testNewestFirst() {
        let a = row(ts(day: 24, hour: 7)), b = row(ts(day: 24, hour: 11)), c = row(ts(day: 24, hour: 9))
        let kept = TodayWorkoutSummary.todaysWorkouts([a, b, c], now: now, calendar: cal)
        XCTAssertEqual(kept.map(\.startTs), [b.startTs, c.startTs, a.startTs])
    }

    // MARK: zone minutes

    func testImportedSplitWinsOverDerived() {
        let json = #"{"z1":0,"z2":0,"z3":50,"z4":50,"z5":0}"#
        let r = row(ts(day: 24, hour: 7), zones: json, durationS: 3_600)
        let m = TodayWorkoutSummary.zoneMinutes(row: r, derived: [60, 0, 0, 0, 0])
        XCTAssertEqual(m?[2] ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(m?[3] ?? 0, 30, accuracy: 0.001)
    }

    func testDerivedUsedWhenNoImportedSplit() {
        let r = row(ts(day: 24, hour: 7))
        XCTAssertEqual(TodayWorkoutSummary.zoneMinutes(row: r, derived: [1, 2, 3, 4, 5]), [1, 2, 3, 4, 5])
        XCTAssertNil(TodayWorkoutSummary.zoneMinutes(row: r, derived: nil))
    }

    // MARK: highlights

    func testHighlightsKeepTheTwoBusiestInZoneOrder() {
        let h = TodayWorkoutSummary.highlights([2, 5, 15, 42, 0])
        XCTAssertEqual(h, [.init(zone: 3, minutes: 15), .init(zone: 4, minutes: 42)])
    }

    func testHighlightsTieGoesToTheHigherZone() {
        let h = TodayWorkoutSummary.highlights([10, 10, 10, 0, 0])
        XCTAssertEqual(h.map(\.zone), [2, 3])
    }

    func testHighlightsDropSubMinuteAndEmpty() {
        XCTAssertTrue(TodayWorkoutSummary.highlights([0.4, 0.2, 0, 0, 0]).isEmpty)
        XCTAssertEqual(TodayWorkoutSummary.highlights([0, 0, 20, 0.3, 0]), [.init(zone: 3, minutes: 20)])
    }

    func testHighlightsIgnoreNonFinite() {
        XCTAssertEqual(TodayWorkoutSummary.highlights([.nan, .infinity, 8, 0, 0]),
                       [.init(zone: 3, minutes: 8)])
    }

    // MARK: sentence (names injected so the test does not depend on the simulator language)

    private let h = [TodayWorkoutSummary.ZoneHighlight(zone: 3, minutes: 15),
                     TodayWorkoutSummary.ZoneHighlight(zone: 4, minutes: 42)]

    func testSentenceEnglish() {
        let s = TodayWorkoutSummary.sentence(
            h, minutesLabel: { "\($0) min" },
            zoneName: { $0 == 3 ? "Aerobic" : "Threshold" }, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(s, "15 min · Aerobic and 42 min · Threshold")
    }

    func testSentenceItalian() {
        let s = TodayWorkoutSummary.sentence(
            h, minutesLabel: { "\($0) min" },
            zoneName: { $0 == 3 ? "Aerobico" : "Soglia" }, locale: Locale(identifier: "it_IT"))
        XCTAssertEqual(s, "15 min · Aerobico e 42 min · Soglia")
    }

    func testSentenceSinglePieceHasNoConjunction() {
        let s = TodayWorkoutSummary.sentence(
            [h[0]], minutesLabel: { "\($0) min" }, zoneName: { _ in "Aerobic" },
            locale: Locale(identifier: "en_US"))
        XCTAssertEqual(s, "15 min · Aerobic")
    }

    func testSentenceNilWhenNothingToSay() {
        XCTAssertNil(TodayWorkoutSummary.sentence([], locale: Locale(identifier: "en_US")))
    }

    // MARK: editability

    func testOnlyManualAndDetectedAreEditable() {
        func with(_ source: String) -> WorkoutRow {
            WorkoutRow(startTs: 1, endTs: 2, sport: "Run", source: source, durationS: nil, energyKcal: nil,
                       avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        }
        XCTAssertTrue(TodayWorkoutSummary.isEditable(with("manual")))
        XCTAssertFalse(TodayWorkoutSummary.isEditable(with("whoop")))
    }
}
