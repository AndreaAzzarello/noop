import XCTest
@testable import Strand

final class SmartWakeFirmwareSkipTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    /// 2026-11-12 is a Thursday (weekday 5); the 13th is a Friday (6).
    private func date(_ hour: Int, _ minute: Int, day: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SmartWakeFirmwareSkipTests.\(UUID().uuidString)")!
    }

    private let wakeMinutes = 7 * 60 + 20

    func testNoSkipRecordedSearchesFromNow() {
        let defaults = makeDefaults()
        let now = date(6, 50)
        XCTAssertEqual(SmartWakeFirmwareSkip.armFrom(now: now, smartWakeEnabled: true, defaults: defaults), now)
    }

    func testSmartWakeOffIgnoresARecordedSkip() {
        let defaults = makeDefaults()
        SmartWakeFirmwareSkip.record(skipUntil: date(7, 20), defaults: defaults)
        let now = date(6, 55)
        XCTAssertEqual(SmartWakeFirmwareSkip.armFrom(now: now, smartWakeEnabled: false, defaults: defaults), now)
        // Not spent: switching Smart Wake back on within the morning still honours it.
        XCTAssertEqual(
            SmartWakeFirmwareSkip.armFrom(now: now, smartWakeEnabled: true, defaults: defaults),
            date(7, 20)
        )
    }

    func testASkipMovesTheNextFirmwareOccurrenceToTomorrow() {
        let defaults = makeDefaults()
        SmartWakeFirmwareSkip.record(skipUntil: date(7, 20), defaults: defaults)
        let from = SmartWakeFirmwareSkip.armFrom(now: date(6, 55), smartWakeEnabled: true, defaults: defaults)

        let next = AppModel.nextSmartAlarmDate(
            minutes: wakeMinutes, weekdays: [], overrides: [:], from: from, calendar: calendar)
        XCTAssertEqual(next, date(7, 20, day: 13))

        // Without the skip the same call would arm this morning's 07:20 again: what the skip prevents.
        let unskipped = AppModel.nextSmartAlarmDate(
            minutes: wakeMinutes, weekdays: [], overrides: [:], from: date(6, 55), calendar: calendar)
        XCTAssertEqual(unskipped, date(7, 20))
    }

    func testTheSkipHoldsOnEveryReArmDuringTheMorning() {
        let defaults = makeDefaults()
        SmartWakeFirmwareSkip.record(skipUntil: date(7, 20), defaults: defaults)
        for minute in [56, 59] {
            let from = SmartWakeFirmwareSkip.armFrom(now: date(6, minute), smartWakeEnabled: true, defaults: defaults)
            XCTAssertEqual(
                AppModel.nextSmartAlarmDate(
                    minutes: wakeMinutes, weekdays: [], overrides: [:], from: from, calendar: calendar),
                date(7, 20, day: 13)
            )
        }
    }

    func testAfterTheMaximumTimeTheSkipIsSpentAndCleared() {
        let defaults = makeDefaults()
        SmartWakeFirmwareSkip.record(skipUntil: date(7, 20), defaults: defaults)
        let now = date(7, 21)
        XCTAssertEqual(SmartWakeFirmwareSkip.armFrom(now: now, smartWakeEnabled: true, defaults: defaults), now)
        XCTAssertNil(defaults.object(forKey: SmartWakeFirmwareSkip.key))
    }

    func testASkipMoreThanADayAheadIsDiscarded() {
        let defaults = makeDefaults()
        SmartWakeFirmwareSkip.record(skipUntil: date(7, 20, day: 15), defaults: defaults)
        let now = date(6, 55)
        XCTAssertEqual(SmartWakeFirmwareSkip.armFrom(now: now, smartWakeEnabled: true, defaults: defaults), now)
        XCTAssertNil(defaults.object(forKey: SmartWakeFirmwareSkip.key))
    }

    func testSelectedWeekdaysAreRespectedAfterTheSkip() {
        // Thursday only: skipping this Thursday means next Thursday, not tomorrow.
        let next = AppModel.nextSmartAlarmDate(
            minutes: wakeMinutes, weekdays: [5], overrides: [:], from: date(7, 20), calendar: calendar)
        XCTAssertEqual(next, date(7, 20, day: 19))
    }

    func testPerDayOverrideOfTheNextDayIsRespectedAfterTheSkip() {
        let next = AppModel.nextSmartAlarmDate(
            minutes: wakeMinutes, weekdays: [], overrides: [6: 8 * 60], from: date(7, 20), calendar: calendar)
        XCTAssertEqual(next, date(8, 0, day: 13))
    }

    func testClearRemovesTheSkip() {
        let defaults = makeDefaults()
        SmartWakeFirmwareSkip.record(skipUntil: date(7, 20), defaults: defaults)
        SmartWakeFirmwareSkip.clear(defaults: defaults)
        let now = date(6, 55)
        XCTAssertEqual(SmartWakeFirmwareSkip.armFrom(now: now, smartWakeEnabled: true, defaults: defaults), now)
    }
}
