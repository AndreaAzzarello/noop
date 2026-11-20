import XCTest

/// The widget announces the window of the alarm that rings next, not a schedule-wide one.
final class ForkNextWakeWindowTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testNextWakeUsesTheWindowOfTheDayThatRings() {
        // 2026-11-12 is a Thursday (5), 2026-11-13 a Friday (6): Friday has its own 45 min window.
        let schedule = SmartWakeSchedule(wakeMinutes: 7 * 60, weekdays: [5, 6], windowDuration: 15 * 60, windowOverrides: [6: 45 * 60])
        var snapshot = ForkWidgetSnapshot.empty
        snapshot.smartWake = schedule
        let thursday = snapshot.nextWake(now: date(12, 0, 0), calendar: calendar)
        XCTAssertEqual(thursday?.latest, date(12, 7, 0))
        XCTAssertEqual(thursday?.windowStart, date(12, 6, 45))
        let friday = snapshot.nextWake(now: date(12, 8, 0), calendar: calendar)
        XCTAssertEqual(friday?.latest, date(13, 7, 0))
        XCTAssertEqual(friday?.windowStart, date(13, 6, 15))
    }

    func testNoScheduleMeansNoNextWake() {
        XCTAssertNil(ForkWidgetSnapshot.empty.nextWake(now: date(12, 0, 0), calendar: calendar))
    }
}
