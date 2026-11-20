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

    // The keys and the JSON layout are part of what an installed build already has on disk.
    private let baselineKey = "smartWake.localBaseline.v1"

    private func storedBaselineCount(_ defaults: UserDefaults) throws -> Int {
        let data = try XCTUnwrap(defaults.data(forKey: baselineKey))
        return try JSONDecoder().decode([SmartWakeHeartRateSample].self, from: data).count
    }

    func testBaselineIsNotWrittenInsideTheIntervalAndFlushWritesIt() throws {
        let defaults = UserDefaults(suiteName: "SmartWakeFlushTests.\(UUID().uuidString)")!
        let controller = SmartWakeLiveController(
            schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20), calendar: calendar, defaults: defaults
        )
        for minute in 0..<4 { _ = controller.ingest(bpm: 60, at: date(6, minute)) }
        XCTAssertEqual(try storedBaselineCount(defaults), 0, "no write inside the persistence interval")

        controller.flushPersistence()
        XCTAssertEqual(try storedBaselineCount(defaults), 4)
    }

    func testBaselineSavedByAnEarlierBuildIsRestored() throws {
        let defaults = UserDefaults(suiteName: "SmartWakeLegacyTests.\(UUID().uuidString)")!
        let samples = (0..<20).map {
            SmartWakeHeartRateSample(bpm: 60, timestamp: date(6, 0).addingTimeInterval(Double($0) * 120))
        }
        defaults.set(try JSONEncoder().encode(samples), forKey: baselineKey)

        let controller = SmartWakeLiveController(
            schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20), calendar: calendar, defaults: defaults
        )
        XCTAssertEqual(controller.ingest(bpm: 66, at: date(6, 50)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 67, at: date(6, 51)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 67, at: date(6, 52)), .wake(.sustainedHeartRateRise))
    }

    func testFlushSavesTheRunningWindowStatistics() {
        let defaults = UserDefaults(suiteName: "SmartWakeStatsFlushTests.\(UUID().uuidString)")!
        let controller = SmartWakeLiveController(
            schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20), calendar: calendar, defaults: defaults
        )
        for minute in 30..<50 { _ = controller.ingest(bpm: 60, at: date(6, minute)) }
        _ = controller.ingest(bpm: 60, at: date(6, 50))
        _ = controller.ingest(bpm: 60, at: date(6, 51))
        let key = SmartWakeLiveController.windowSummaryStorageKey
        XCTAssertTrue(defaults.string(forKey: key)?.contains("samples=1") == true)

        controller.flushPersistence()
        XCTAssertTrue(defaults.string(forKey: key)?.hasPrefix("in progress: samples=2") == true)
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

    func testNextWakeSkipsPassedOccurrenceAndHonorsSelectedWeekdayOverride() {
        let schedule = SmartWakeSchedule(
            wakeMinutes: 7 * 60,
            weekdays: [6],
            overrides: [6: 8 * 60 + 15]
        )
        let afterFridayWake = date(9, 0, day: 13)
        XCTAssertEqual(
            schedule.nextMaximumWakeTime(after: afterFridayWake, calendar: calendar),
            date(8, 15, day: 20)
        )
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
        first.flushPersistence() // what the app does when it moves to the background

        let relaunched = SmartWakeLiveController(schedule: schedule, calendar: calendar, defaults: defaults)
        XCTAssertEqual(relaunched.ingest(bpm: 66, at: date(6, 50)), .waiting)
        XCTAssertEqual(relaunched.ingest(bpm: 67, at: date(6, 51)), .waiting)
        XCTAssertEqual(relaunched.ingest(bpm: 67, at: date(6, 52)), .wake(.sustainedHeartRateRise))
    }

    func testWindowStatsCountSamplesGapAndForegroundState() {
        let controller = makeController(schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20))
        for minute in 30..<50 { _ = controller.ingest(bpm: 60, at: date(6, minute)) }
        XCTAssertEqual(controller.windowStats.sampleCount, 0, "baseline samples are not window samples")

        _ = controller.ingest(bpm: 60, at: date(6, 50), isForeground: false)
        _ = controller.ingest(bpm: 60, at: date(6, 51), isForeground: false)
        _ = controller.ingest(bpm: 60, at: date(6, 55), isForeground: true)

        let stats = controller.windowStats
        XCTAssertEqual(stats.sampleCount, 3)
        XCTAssertEqual(stats.firstSampleAt, date(6, 50))
        XCTAssertEqual(stats.lastSampleAt, date(6, 55))
        XCTAssertEqual(stats.maximumGap, 240)
        XCTAssertEqual(stats.backgroundCount, 2)
        XCTAssertEqual(stats.foregroundCount, 1)
    }

    func testWindowSummaryIsReportedOnceWhenTheWindowEnds() {
        let controller = makeController(schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20))
        var summaries: [String] = []
        controller.onWindowSummary = { summaries.append($0) }

        _ = controller.ingest(bpm: 60, at: date(6, 50))
        _ = controller.ingest(bpm: 60, at: date(6, 51))
        XCTAssertTrue(summaries.isEmpty)

        _ = controller.ingest(bpm: 60, at: date(7, 21))
        _ = controller.ingest(bpm: 60, at: date(7, 22))
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(summaries[0].contains("samples=2"))
        XCTAssertEqual(controller.windowStats.sampleCount, 0)
    }

    func testLateLaunchDoesNotTriggerEarlyAndUsesMaximumDeadline() {
        let controller = makeController(schedule: SmartWakeSchedule(wakeHour: 7, wakeMinute: 20))

        XCTAssertEqual(controller.ingest(bpm: 70, at: date(7, 10)), .waiting)
        XCTAssertEqual(controller.evaluate(at: date(7, 19)), .waiting)
        XCTAssertEqual(controller.evaluate(at: date(7, 20)), .wake(.maximumWakeTime))
    }

    // Alarm list: each weekday carries its own early window.
    func testTheDetectionWindowIsTheOneOfTheDayThatRings() {
        // Friday (6) rings at 09:30 with a 45 min window; every other day uses 15 min.
        let schedule = SmartWakeSchedule(
            wakeMinutes: 9 * 60 + 30, weekdays: [6], windowDuration: 15 * 60, windowOverrides: [6: 45 * 60])
        let controller = makeController(schedule: schedule)
        for minute in 0..<45 { XCTAssertEqual(controller.ingest(bpm: 60, at: date(8, minute, day: 13)), .waiting) }
        XCTAssertEqual(controller.ingest(bpm: 66, at: date(8, 45, day: 13)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 67, at: date(8, 46, day: 13)), .waiting)
        XCTAssertEqual(controller.ingest(bpm: 67, at: date(8, 47, day: 13)), .wake(.sustainedHeartRateRise))
    }

    func testADayWithoutItsOwnWindowKeepsTheScheduleWideOne() {
        let schedule = SmartWakeSchedule(
            wakeMinutes: 9 * 60 + 30, weekdays: [5, 6], windowDuration: 15 * 60, windowOverrides: [6: 45 * 60])
        XCTAssertEqual(schedule.windowDuration(for: date(9, 30, day: 12), calendar: calendar), 15 * 60)
        XCTAssertEqual(schedule.windowDuration(for: date(9, 30, day: 13), calendar: calendar), 45 * 60)
    }

    func testRetentionUsesTheLongestWindowOfTheActiveDays() {
        let schedule = SmartWakeSchedule(
            wakeMinutes: 7 * 60, weekdays: [2, 3], windowDuration: 15 * 60, windowOverrides: [3: 60 * 60])
        XCTAssertEqual(schedule.longestWindowDuration, 60 * 60)
        // An override on a day that is not active does not count.
        let inactive = SmartWakeSchedule(
            wakeMinutes: 7 * 60, weekdays: [2], windowDuration: 15 * 60, windowOverrides: [3: 60 * 60])
        XCTAssertEqual(inactive.longestWindowDuration, 15 * 60)
        XCTAssertEqual(SmartWakeSchedule.standard.longestWindowDuration, SmartWakeSchedule.standard.windowDuration)
    }

    func testInsistenceIsPerAlarmOnceAListExists() {
        XCTAssertNil(SmartWakeInsistence.resolve(bookExists: false, scheduleSaysInsistent: true), "no list: the global switch decides")
        XCTAssertNil(SmartWakeInsistence.resolve(bookExists: false, scheduleSaysInsistent: nil))
        XCTAssertEqual(SmartWakeInsistence.resolve(bookExists: true, scheduleSaysInsistent: true), true)
        XCTAssertEqual(SmartWakeInsistence.resolve(bookExists: true, scheduleSaysInsistent: false), false)
        XCTAssertEqual(SmartWakeInsistence.resolve(bookExists: true, scheduleSaysInsistent: nil), false)
    }
}
