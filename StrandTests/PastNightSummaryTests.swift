import XCTest
import WhoopStore
@testable import Strand

final class PastNightSummaryTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }

    private func ts(day: Int, hour: Int, minute: Int = 0) -> Int {
        Int(cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!.timeIntervalSince1970)
    }

    private func session(endDay: Int, endHour: Int, hours: Int) -> CachedSleepSession {
        let end = ts(day: endDay, hour: endHour)
        return CachedSleepSession(startTs: end - hours * 3_600, endTs: end, efficiency: 0.9, restingHr: 50,
                                  avgHrv: 60, stagesJSON: nil)
    }

    private func metric(total: Double?) -> DailyMetric {
        DailyMetric(day: "2026-11-25", totalSleepMin: total, efficiency: 0.9, deepMin: 80, remMin: 90, lightMin: 220,
                    disturbances: 2, restingHr: 48, avgHrv: 71, recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testWindowKeepsTheNightThatEndedOnTheDayAndDropsTheNeighbours() {
        let dayStart = cal.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        let thisNight = session(endDay: 25, endHour: 7, hours: 8)
        let previousNight = session(endDay: 24, endHour: 7, hours: 8)
        let nextNight = session(endDay: 26, endHour: 7, hours: 8)
        let nap = session(endDay: 25, endHour: 15, hours: 1)
        let kept = PastNight.windowSessions([previousNight, thisNight, nap, nextNight], dayStart: dayStart, calendar: cal)
        XCTAssertEqual(kept.map(\.endTs), [thisNight.endTs, nap.endTs])
    }

    func testHasSleepNeedsAFinitePositiveTotal() {
        XCTAssertTrue(PastNight.hasSleep(metric(total: 420)))
        XCTAssertFalse(PastNight.hasSleep(metric(total: nil)))
        XCTAssertFalse(PastNight.hasSleep(metric(total: 0)))
        XCTAssertFalse(PastNight.hasSleep(metric(total: .nan)))
        XCTAssertFalse(PastNight.hasSleep(nil))
    }

    func testSummaryCarriesTheSleepAndNeverAnAlarm() {
        let span = (start: ts(day: 24, hour: 23), end: ts(day: 25, hour: 7))
        let s = PastNight.summary(metric: metric(total: 390), span: span, sleepNeedMinutes: 480, now: Date())
        XCTAssertEqual(s.sleepMinutes, 390)
        XCTAssertEqual(s.bedTs, span.start)
        XCTAssertEqual(s.wakeTs, span.end)
        XCTAssertEqual(s.needDelta, -90)
        XCTAssertEqual(s.restingHr, 48)
        XCTAssertEqual(s.hrvMs, 71)
        XCTAssertNil(s.nextAlarm)
        XCTAssertNil(s.bedtime)
        XCTAssertNil(s.outcome)
        XCTAssertNil(s.earlyWakeAt)
    }

    func testNoSleepTotalGivesNoSummary() {
        let s = PastNight.summary(metric: metric(total: nil), span: nil, sleepNeedMinutes: 480, now: Date())
        XCTAssertFalse(s.hasSleep)
    }
}
