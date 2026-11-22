import XCTest
@testable import Strand

/// fork: the figures the fuller Night card adds: the efficiency scale, time awake, wake-ups, the need, the night's
/// vitals and how the last Smart Wake ended.
final class NightSummaryFigureTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(total: Double? = 452, eff: Double? = 0.94, bed: Int? = 0, wake: Int? = 9 * 3600,
                      disturbances: Int? = 3, restingHr: Int? = 48, hrv: Double? = 62.4, need: Int = 480,
                      early: Date? = nil, earlyMax: Date? = nil, maxAt: Date? = nil) -> NightSummary {
        NightSummary.make(.init(
            totalSleepMin: total, efficiency: eff, deepMin: 80, remMin: 105, lightMin: 267, bedTs: bed, wakeTs: wake,
            earlyWakeAt: early, smartWake: nil, strapAlarm: nil, sleepNeedMinutes: need, now: now,
            disturbances: disturbances, restingHr: restingHr, avgHrv: hrv, earlyWakeMaximum: earlyMax, maximumTimeAt: maxAt))
    }

    // MARK: Efficiency scale

    func testAFractionIsShownAsAPercentage() {
        XCTAssertEqual(NightSummary.efficiencyPercent(0.94), 94)
        XCTAssertEqual(make(eff: 0.94).efficiencyPct, 94, "the strap's 0.94 used to read 1%")
    }

    func testAPercentageStaysAsIs() {
        XCTAssertEqual(NightSummary.efficiencyPercent(91), 91)
        XCTAssertEqual(NightSummary.efficiencyPercent(100), 100)
        XCTAssertEqual(NightSummary.efficiencyPercent(1), 100, "1 is a full fraction, the same rule as the watch bridge")
    }

    func testUnknownOrImpossibleEfficiencyIsNotStated() {
        XCTAssertNil(NightSummary.efficiencyPercent(nil))
        XCTAssertNil(NightSummary.efficiencyPercent(0))
        XCTAssertNil(NightSummary.efficiencyPercent(-3))
        XCTAssertNil(NightSummary.efficiencyPercent(140))
        XCTAssertNil(NightSummary.efficiencyPercent(.nan))
    }

    // MARK: Awake time and wake-ups

    func testAwakeIsTimeInBedMinusSleep() {
        // 9 h in bed, 452 min asleep: 88 min awake.
        XCTAssertEqual(make().awakeMinutes, 88)
    }

    func testAwakeNeedsAtLeastAMinuteAndASpan() {
        XCTAssertNil(make(total: 540).awakeMinutes)
        XCTAssertNil(make(bed: nil).awakeMinutes)
        XCTAssertNil(make(bed: 100, wake: 100).awakeMinutes)
        XCTAssertNil(make(total: 600).awakeMinutes, "more sleep than time in bed is not awake time")
    }

    func testWakingsOnlyWhenCounted() {
        XCTAssertEqual(make(disturbances: 3).wakings, 3)
        XCTAssertNil(make(disturbances: 0).wakings)
        XCTAssertNil(make(disturbances: nil).wakings)
    }

    // MARK: Need

    func testNeedDeltaIsADebtOrASurplus() {
        XCTAssertEqual(make(total: 452, need: 480).needDelta, -28)
        XCTAssertEqual(make(total: 536, need: 480).needDelta, 56)
        XCTAssertNil(make(total: nil).needDelta)
    }

    // MARK: Vitals

    func testVitals() {
        let s = make()
        XCTAssertEqual(s.restingHr, 48)
        XCTAssertEqual(s.hrvMs, 62)
        XCTAssertNil(make(restingHr: nil, hrv: nil).restingHr)
        XCTAssertNil(make(restingHr: 0, hrv: 0).hrvMs)
        XCTAssertNil(make(hrv: .nan).hrvMs)
    }

    func testNoSleepDropsTheNewFigures() {
        let s = make(total: nil, early: now)
        XCTAssertNil(s.awakeMinutes)
        XCTAssertNil(s.wakings)
        XCTAssertNil(s.restingHr)
        XCTAssertNil(s.hrvMs)
        XCTAssertNil(s.outcome)
    }

    // MARK: Outcome

    func testEarlyWakeNamesTheMinutesBeforeTheMaximumTime() {
        let at = now.addingTimeInterval(-3_600)
        let s = make(early: at, earlyMax: at.addingTimeInterval(22 * 60))
        XCTAssertEqual(s.outcome, .early(at: at, minutesBefore: 22))
    }

    func testEarlyWakeWithoutARecordedMaximumStatesOnlyTheTime() {
        let at = now.addingTimeInterval(-3_600)
        XCTAssertEqual(make(early: at).outcome, .early(at: at, minutesBefore: nil))
        // A maximum that is not after the wake adds nothing: it is not "early".
        XCTAssertEqual(make(early: at, earlyMax: at).outcome, .early(at: at, minutesBefore: nil))
        XCTAssertEqual(make(early: at, earlyMax: at.addingTimeInterval(-60)).outcome, .early(at: at, minutesBefore: nil))
    }

    func testTheMaximumTimeOutcome() {
        let at = now.addingTimeInterval(-1_800)
        XCTAssertEqual(make(maxAt: at).outcome, .maximum(at: at))
    }

    func testAnEarlyWakeWinsOverAMaximumTimeRecord() {
        let early = now.addingTimeInterval(-3_600)
        XCTAssertEqual(make(early: early, maxAt: now).outcome, .early(at: early, minutesBefore: nil))
    }

    func testNoRecordNoOutcome() {
        XCTAssertNil(make().outcome)
    }
}
