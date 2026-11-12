import XCTest

final class SmartWakeLiveControllerTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ hour: Int, _ minute: Int, day: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func makeController(schedule: SmartWakeSchedule = .standard) -> SmartWakeLiveController {
        let defaults = UserDefaults(suiteName: "SmartWakeLiveControllerTests.\(UUID().uuidString)")!
        return SmartWakeLiveController(schedule: schedule, calendar: calendar, defaults: defaults)
    }

    func testDefaultScheduleTriggersWithConfiguredWindow() {
        let controller = makeController(schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20))

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
        let controller = makeController(schedule: schedule)

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
        let controller = makeController(schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20))

        for minute in 45..<50 {
            _ = controller.ingest(bpm: 60, at: date(6, minute))
        }

        XCTAssertEqual(controller.ingest(bpm: 90, at: date(6, 50)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 95, at: date(6, 51)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 96, at: date(6, 52)), .waiting)
        XCTAssertEqual(controller.evaluate(at: date(7, 20)), .wake(.maximumWakeTime))
    }

    func testOutOfOrderSamplesAreIgnored() {
        let controller = makeController(schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20))
        _ = controller.ingest(bpm: 60, at: date(6, 30))
        _ = controller.ingest(bpm: 60, at: date(6, 31))

        XCTAssertEqual(controller.ingest(bpm: 100, at: date(6, 30)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 60, at: date(6, 32)), .waiting)
    }


    func testPerDayOverrideAndWeekdaySelectionAreUsedForMaximumWake() {
        let schedule = SmartWakeSchedule(
            wakeMinutes: 7 * 60,
            weekdays: [6],
            overrides: [6: 8 * 60 + 15],
            windowDuration: 45 * 60
        )
        let friday = date(0, 0, day: 13)
        XCTAssertNil(schedule.maximumWakeTime(on: date(8, 0), calendar: calendar))
        XCTAssertEqual(schedule.maximumWakeTime(on: friday, calendar: calendar), date(8, 15, day: 13))
    }

    func testBaselineFromPreviousDaySurvivesMidnightForCrossDayWindow() {
        let schedule = SmartWakeSchedule(
            wakeHour: 0,
            wakeMinute: 30,
            windowDuration: 30 * 60,
            baselineLookback: 60 * 60
        )
        let controller = makeController(schedule: schedule)

        for minute in 0..<20 {
            XCTAssertEqual(controller.ingest(bpm: 60, at: date(23, minute, day: 11)), .waiting)
        }

        XCTAssertEqual(controller.ingest(bpm: 66, at: date(0, 0)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 67, at: date(0, 1)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 67, at: date(0, 2)), .wake(.sustainedHeartRateRise))
    }

    func testBaselineIsRestoredAcrossControllerRestart() {
        let defaults = UserDefaults(suiteName: "SmartWakeRestartTests.\(UUID().uuidString)")!
        let schedule = SmartWakeSchedule(wakeHour: 7, wakeMinute: 20)
        let first = SmartWakeLiveController(schedule: schedule, calendar: calendar, defaults: defaults)

        for minute in stride(from: 0, to: 40, by: 2) {
            XCTAssertEqual(first.ingest(bpm: 60, at: date(6, minute)), .waiting)
        }

        let relaunched = SmartWakeLiveController(schedule: schedule, calendar: calendar, defaults: defaults)
        XCTAssertEqual(relaunched.ingest(bpm: 66, at: date(6, 50)), .waiting)
        XCTAssertEqual(relaunched.ingest(bpm: 67, at: date(6, 51)), .waiting)
        XCTAssertEqual(relaunched.ingest(bpm: 67, at: date(6, 52)), .wake(.sustainedHeartRateRise))
    }

    func testLateLaunchDoesNotTriggerEarlyAndUsesMaximumDeadline() {
        let controller = makeController(schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20))

        XCTAssertEqual(controller.ingest(bpm: 70, at: date(7, 10)), .waiting)
        XCTAssertEqual(controller.evaluate(at: date(7, 19)), .waiting)
        XCTAssertEqual(controller.evaluate(at: date(7, 20)), .wake(.maximumWakeTime))
    }
}
