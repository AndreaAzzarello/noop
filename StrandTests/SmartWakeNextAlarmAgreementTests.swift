import XCTest
@testable import Strand

/// The reported scenario: "Weekdays" 07:20 (Mon-Fri, insistent) + "Sun" 12:00 (insistent). Every readout of "the next
/// alarm" must name Sunday 12:00 on Saturday evening, and Monday 07:20 once Sunday has passed.
final class SmartWakeNextAlarmAgreementTests: XCTestCase {

    private var rome: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        rome.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func book() -> SmartWakeAlarmBook {
        let weekdays = SmartWakeAlarm(label: "Giorni feriali", wakeMinutes: 7 * 60 + 20, weekdays: [2, 3, 4, 5, 6],
                                      insistent: true, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let sunday = SmartWakeAlarm(label: "dom", wakeMinutes: 12 * 60, weekdays: [1], insistent: true,
                                    createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        return SmartWakeAlarmBook(alarms: [weekdays, sunday])
    }

    /// An in-memory upstream store.
    private final class MemoryStore: SmartWakeUpstreamStore {
        var settings: SmartWakeUpstreamSettings
        init(_ settings: SmartWakeUpstreamSettings) { self.settings = settings }
        func setMinutes(_ minutes: Int) { settings.minutes = minutes }
        func setWeekdays(_ weekdays: Set<Int>) { settings.weekdays = weekdays }
        func setOverride(weekday: Int, minutes: Int?) { settings.overrides[weekday] = minutes }
    }

    /// The upstream settings as they were before the Sunday alarm existed: Mon-Fri 07:20, no override.
    private func mirroredStore() -> MemoryStore {
        let store = MemoryStore(.init(minutes: 7 * 60 + 20, weekdays: [2, 3, 4, 5, 6], overrides: [:]))
        SmartWakeUpstreamMirror.apply(effectiveMinutes: book().effectiveDays().mapValues(\.minutes), to: store)
        return store
    }

    func testMirrorWritesTheSundayOverride() {
        let settings = mirroredStore().settings
        XCTAssertEqual(settings.minutes, 7 * 60 + 20)
        XCTAssertEqual(settings.weekdays, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(settings.overrides, [1: 12 * 60])
    }

    func testEveryResolverNamesSundayNoonOnSaturdayEvening() {
        let now = date(2026, 11, 21, 16)           // Saturday
        let sundayNoon = date(2026, 11, 22, 12)
        let s = mirroredStore().settings

        // The strap alarm, from the mirrored upstream values (what applySmartAlarm and the Night card pass).
        XCTAssertEqual(AppModel.nextSmartAlarmDate(minutes: s.minutes, weekdays: s.weekdays, overrides: s.overrides,
                                                   from: now, calendar: rome), sundayNoon)
        // Smart Wake / AlarmKit / the detector, from the list.
        let specs = book().effectiveDays().mapValues {
            SmartWakeDaySpec(minutes: $0.minutes, windowMinutes: $0.windowMinutes, label: $0.label, insistent: $0.insistent)
        }
        let schedule = SmartWakeSchedule.compiled(days: specs)
        XCTAssertEqual(schedule?.nextMaximumWakeTime(after: now, calendar: rome), sundayNoon)
    }

    func testMondayFollowsSundayNoon() {
        let s = mirroredStore().settings
        let sundayAfternoon = date(2026, 11, 22, 13)
        XCTAssertEqual(AppModel.nextSmartAlarmDate(minutes: s.minutes, weekdays: s.weekdays, overrides: s.overrides,
                                                   from: sundayAfternoon, calendar: rome), date(2026, 11, 23, 7, 20))
    }

    /// The defect: the Alarms screen held the overrides it read when it opened (`@State`), so after the list added the
    /// Sunday alarm it combined the NEW day set with the OLD (empty) overrides and named Sunday at the base time.
    func testStaleOverridesNameTheBaseTimeOnSunday() {
        let s = mirroredStore().settings
        let stale = AppModel.nextSmartAlarmDate(minutes: s.minutes, weekdays: s.weekdays, overrides: [:],
                                                from: date(2026, 11, 21, 16), calendar: rome)
        XCTAssertEqual(stale, date(2026, 11, 22, 7, 20))   // "Sunday 07:20", as reported
        XCTAssertNotEqual(stale, date(2026, 11, 22, 12))
    }
}
