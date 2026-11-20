import XCTest
@testable import Strand

final class SmartWakeScheduleWeekdayTests: XCTestCase {
    /// The schedule exactly as it was declared before the alarm list: the coder it got was the synthesized one, so
    /// encoding this mirror gives the bytes an older build wrote to UserDefaults and to the widget snapshot.
    private struct LegacySchedule: Codable {
        let wakeMinutes: Int
        let weekdays: Set<Int>
        let overrides: [Int: Int]
        let windowDuration: TimeInterval
        let baselineLookback: TimeInterval
    }

    private func rome() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    // MARK: Legacy compatibility

    func testALegacyBlobDecodesToTheSameScheduleWithNoPerDayData() throws {
        let legacy = LegacySchedule(wakeMinutes: 7 * 60 + 20, weekdays: [2, 3, 4], overrides: [4: 8 * 60],
                                    windowDuration: 45 * 60, baselineLookback: 60 * 60)
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SmartWakeSchedule.self, from: data)
        XCTAssertEqual(decoded, SmartWakeSchedule(wakeMinutes: 7 * 60 + 20, weekdays: [2, 3, 4], overrides: [4: 8 * 60],
                                                  windowDuration: 45 * 60, baselineLookback: 60 * 60))
        XCTAssertTrue(decoded.windowOverrides.isEmpty)
        XCTAssertTrue(decoded.labels.isEmpty)
        XCTAssertTrue(decoded.insistentDays.isEmpty)
        // Without a per-day value every weekday uses the schedule-wide window.
        for day in 1...7 { XCTAssertEqual(decoded.windowDuration(onWeekday: day), 45 * 60) }
    }

    func testAScheduleWithoutPerDayDataEncodesWithTheLegacyKeysOnly() throws {
        let schedule = SmartWakeSchedule(wakeMinutes: 420, weekdays: [2, 6], overrides: [6: 500], windowDuration: 1800)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(schedule)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["wakeMinutes", "weekdays", "overrides", "windowDuration", "baselineLookback"])
        // And what it writes is what a legacy reader would have written: decode it with the legacy type.
        let back = try JSONDecoder().decode(LegacySchedule.self, from: JSONEncoder().encode(schedule))
        XCTAssertEqual(back.wakeMinutes, 420)
        XCTAssertEqual(back.weekdays, [2, 6])
        XCTAssertEqual(back.overrides, [6: 500])
    }

    func testPerDayDataRoundTrips() throws {
        let schedule = SmartWakeSchedule(
            wakeMinutes: 6 * 60 + 45, weekdays: [2, 3, 5, 6], overrides: [5: 7 * 60],
            windowDuration: 30 * 60,
            windowOverrides: [5: 20 * 60, 6: 20 * 60], labels: [2: "Work", 3: "Work", 5: "Other"], insistentDays: [2, 3])
        let data = try JSONEncoder().encode(schedule)
        XCTAssertEqual(try JSONDecoder().decode(SmartWakeSchedule.self, from: data), schedule)
    }

    func testEqualSchedulesEncodeToEqualPerDayBytes() throws {
        let make = {
            SmartWakeSchedule(weekdays: Set(1...7), windowOverrides: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 900.0) }),
                              labels: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, "d\($0)") }), insistentDays: Set(1...7))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(make())
        for _ in 0..<10 { XCTAssertEqual(try encoder.encode(make()), first) }
    }

    func testDuplicateDayKeysInAHandEditedBlobDoNotTrap() throws {
        let json = #"{"wakeMinutes":420,"weekdays":[2],"overrides":{},"windowDuration":1800,"baselineLookback":3600,"windowOverrides":{"1":600,"01":900},"labels":{"1":"a","01":"b"}}"#
        let decoded = try JSONDecoder().decode(SmartWakeSchedule.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.windowOverrides.count, 1)
        XCTAssertEqual(decoded.labels.count, 1)
    }

    // MARK: Accessors and clamping

    func testPerDayAccessors() {
        let s = SmartWakeSchedule(weekdays: [2, 5], windowDuration: 1800, windowOverrides: [5: 1200],
                                  labels: [2: "Work"], insistentDays: [2])
        XCTAssertEqual(s.windowDuration(onWeekday: 2), 1800)
        XCTAssertEqual(s.windowDuration(onWeekday: 5), 1200)
        XCTAssertEqual(s.label(onWeekday: 2), "Work")
        XCTAssertNil(s.label(onWeekday: 5))
        XCTAssertTrue(s.isInsistent(onWeekday: 2))
        XCTAssertFalse(s.isInsistent(onWeekday: 5))
    }

    func testWindowForAMaximumWakeTimeFollowsItsWeekday() {
        let calendar = rome()
        let s = SmartWakeSchedule(weekdays: [2, 5], windowDuration: 1800, windowOverrides: [5: 1200])
        // 2026-11-16 is a Monday (2); 2026-11-19 a Thursday (5).
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 7))!
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 7))!
        XCTAssertEqual(s.windowDuration(for: monday, calendar: calendar), 1800)
        XCTAssertEqual(s.windowDuration(for: thursday, calendar: calendar), 1200)
    }

    func testPerDayValuesAreClampedAndCleaned() {
        let s = SmartWakeSchedule(windowOverrides: [1: 99_999, 9: 600, 2: -5],
                                  labels: [1: "  ", 2: String(repeating: "x", count: 50), 8: "no"], insistentDays: [0, 3, 12])
        XCTAssertEqual(s.windowOverrides, [1: 3 * 60 * 60, 2: 0])
        XCTAssertEqual(s.labels.keys.sorted(), [2])
        XCTAssertEqual(s.labels[2]?.count, 32)
        XCTAssertEqual(s.insistentDays, [3])
    }

    // MARK: Next maximum wake time (these paths feed the early-wake window and the widget)

    func testNextMaximumWakeTimeCrossesMidnightForAWindowThatStartsTheDayBefore() {
        let calendar = rome()
        // Alarm at 00:30 every day with a 60 min window: the window opens at 23:30 the evening before.
        let s = SmartWakeSchedule(wakeMinutes: 30, windowDuration: 3600)
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 23, minute: 45))!
        let next = s.nextMaximumWakeTime(after: evening, calendar: calendar)
        XCTAssertEqual(next, calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 0, minute: 30)))
        XCTAssertTrue(evening >= next!.addingTimeInterval(-s.windowDuration(for: next!, calendar: calendar)))
    }

    func testNextMaximumWakeTimeSkipsADayThatHasNoAlarm() {
        let calendar = rome()
        let s = SmartWakeSchedule(wakeMinutes: 7 * 60, weekdays: [2, 5])   // Monday and Thursday
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))!
        XCTAssertEqual(s.nextMaximumWakeTime(after: tuesday, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 7)))
    }

    func testNextMaximumWakeTimeAcrossTheSpringDSTChange() {
        let calendar = rome()
        // Europe/Rome moves to summer time on Sunday 2026-03-29 (02:00 -> 03:00). 07:00 stays 07:00 on the wall clock,
        // so the gap between Saturday's and Sunday's alarm is 23 hours.
        let s = SmartWakeSchedule(wakeMinutes: 7 * 60)
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 7, minute: 1))!
        let next = s.nextMaximumWakeTime(after: saturday, calendar: calendar)
        XCTAssertEqual(next, calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 7)))
        let previous = calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 7))!
        XCTAssertEqual(next!.timeIntervalSince(previous), 23 * 3600)
    }

    func testNextMaximumWakeTimeAcrossTheAutumnDSTChange() {
        let calendar = rome()
        // Back to winter time on Sunday 2026-10-25 (03:00 -> 02:00): the gap becomes 25 hours.
        let s = SmartWakeSchedule(wakeMinutes: 7 * 60)
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 7, minute: 1))!
        let next = s.nextMaximumWakeTime(after: saturday, calendar: calendar)
        XCTAssertEqual(next, calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 7)))
        let previous = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 7))!
        XCTAssertEqual(next!.timeIntervalSince(previous), 25 * 3600)
    }
}
