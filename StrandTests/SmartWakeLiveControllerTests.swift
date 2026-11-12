import XCTest

final class SmartWakeLiveControllerTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: hour, minute: minute))!
    }

    func testDefaultScheduleTriggersWithConfiguredWindow() {
        let controller = SmartWakeLiveController(calendar: calendar)

        for minute in 30..<50 {
            XCTAssertEqual(controller.ingest(bpm: 60, at: date(6, minute)), .waiting)
        }

        XCTAssertEqual(controller.ingest(bpm: 66, at: date(6, 50)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 67, at: date(6, 51)), .waiting)
        XCTAssertEqual(
            controller.ingest(bpm: 67, at: date(6, 52)),
            .wake(.sustainedHeartRateRise)
        )
    }

    func testChangingMaximumWakeTimeAndWindowKeepsSameDetectionPrinciple() {
        let schedule = SmartWakeSchedule(
            wakeHour: 9,
            wakeMinute: 30,
            windowDuration: 45 * 60
        )
        let controller = SmartWakeLiveController(schedule: schedule, calendar: calendar)

        for minute in 0..<45 {
            XCTAssertEqual(controller.ingest(bpm: 60, at: date(8, minute)), .waiting)
        }

        XCTAssertEqual(controller.ingest(bpm: 66, at: date(8, 45)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 67, at: date(8, 46)), .waiting)
        XCTAssertEqual(
            controller.ingest(bpm: 67, at: date(8, 47)),
            .wake(.sustainedHeartRateRise)
        )
    }

    func testInsufficientBaselineNeverTriggersEarly() {
        let controller = SmartWakeLiveController(calendar: calendar)

        for minute in 45..<50 {
            _ = controller.ingest(bpm: 60, at: date(6, minute))
        }

        XCTAssertEqual(controller.ingest(bpm: 90, at: date(6, 50)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 95, at: date(6, 51)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 96, at: date(6, 52)), .waiting)
        XCTAssertEqual(controller.evaluate(at: date(7, 20)), .wake(.maximumWakeTime))
    }

    func testOutOfOrderSamplesAreIgnored() {
        let controller = SmartWakeLiveController(calendar: calendar)
        _ = controller.ingest(bpm: 60, at: date(6, 30))
        _ = controller.ingest(bpm: 60, at: date(6, 31))

        XCTAssertEqual(controller.ingest(bpm: 100, at: date(6, 30)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 60, at: date(6, 32)), .waiting)
    }

    func testLateLaunchDoesNotTriggerEarlyAndUsesMaximumDeadline() {
        let controller = SmartWakeLiveController(calendar: calendar)

        XCTAssertEqual(controller.ingest(bpm: 70, at: date(7, 10)), .waiting)
        XCTAssertEqual(controller.evaluate(at: date(7, 19)), .waiting)
        XCTAssertEqual(controller.evaluate(at: date(7, 20)), .wake(.maximumWakeTime))
    }
}
