import XCTest
@testable import Strand

final class SmartWakeAlarmBookTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SmartWakeAlarmBookTests.\(UUID().uuidString)")!
    }

    private func alarm(_ label: String, days: Set<Int>, minutes: Int = 7 * 60, enabled: Bool = true,
                       age: TimeInterval = 0) -> SmartWakeAlarm {
        SmartWakeAlarm(label: label, isEnabled: enabled, wakeMinutes: minutes, weekdays: days,
                       createdAt: Date(timeIntervalSince1970: 1_700_000_000 + age))
    }

    // MARK: Model

    func testSanitizingClampsEveryField() {
        let a = SmartWakeAlarm(label: "  " + String(repeating: "x", count: 50) + "  ", wakeMinutes: 99_999,
                               dayOverrides: [1: 600, 2: 5000, 9: 60], weekdays: [1, 9, 0], windowMinutes: 25)
        XCTAssertEqual(a.label.count, SmartWakeAlarm.maximumLabelLength)
        XCTAssertEqual(a.wakeMinutes, 24 * 60 - 1)
        XCTAssertEqual(a.weekdays, [1])
        XCTAssertEqual(a.dayOverrides, [1: 600])   // day 2 is not a weekday of the alarm, 9 is invalid
        XCTAssertEqual(a.windowMinutes, SmartWakeAlarm.defaultWindowMinutes)
    }

    func testEffectiveDaysUseOverridesAndSkipDisabledAlarms() {
        var work = alarm("Work", days: [2, 3, 4], minutes: 6 * 60 + 45)
        work.dayOverrides = [4: 8 * 60]
        let off = alarm("Off", days: [5, 6], enabled: false)
        let book = SmartWakeAlarmBook(alarms: [work, off])
        let days = book.effectiveDays()
        XCTAssertEqual(Set(days.keys), [2, 3, 4])
        XCTAssertEqual(days[2]?.minutes, 6 * 60 + 45)
        XCTAssertEqual(days[4]?.minutes, 8 * 60)
        XCTAssertEqual(days[3]?.label, "Work")
        XCTAssertTrue(book.hasActiveAlarm)
        XCTAssertFalse(SmartWakeAlarmBook(alarms: [off]).hasActiveAlarm)
    }

    func testStoredDoubleBookingResolvesToTheOlderAlarmAndIsReported() {
        let older = alarm("Old", days: [2, 3], age: 0)
        let newer = alarm("New", days: [3, 4], age: 100)
        let book = SmartWakeAlarmBook(alarms: [newer, older])
        XCTAssertEqual(book.effectiveDays()[3]?.alarmID, older.id)
        XCTAssertEqual(book.effectiveDays()[4]?.alarmID, newer.id)
        XCTAssertEqual(book.doubleBookedDays(), [3])
    }

    // MARK: Overlap rule

    func testNoOverlapForDisjointDays() {
        let work = alarm("Work", days: [2, 3, 4])
        let other = alarm("Other", days: [5, 6])
        XCTAssertTrue(SmartWakeAlarmOverlap.conflicts(activating: other, in: [work, other]).isEmpty)
    }

    func testPartialAndTotalOverlapNameTheSharedDays() {
        let work = alarm("Work", days: [2, 3, 4])
        let partial = alarm("Mid", days: [4, 5])
        let total = alarm("Same", days: [2, 3, 4])
        XCTAssertEqual(SmartWakeAlarmOverlap.conflicts(activating: partial, in: [work]).first?.days, [4])
        XCTAssertEqual(SmartWakeAlarmOverlap.conflicts(activating: total, in: [work]).first?.days, [2, 3, 4])
    }

    func testSeveralConflictsAreListedOldestFirst() {
        let a = alarm("A", days: [2], age: 10)
        let b = alarm("B", days: [3], age: 0)
        let c = alarm("C", days: [2, 3, 4])
        XCTAssertEqual(SmartWakeAlarmOverlap.conflicts(activating: c, in: [a, b]).map(\.label), ["B", "A"])
    }

    func testDisabledAlarmsAndTheAlarmItselfNeverConflict() {
        let off = alarm("Off", days: [2, 3], enabled: false)
        let me = alarm("Me", days: [2, 3])
        XCTAssertTrue(SmartWakeAlarmOverlap.conflicts(activating: me, in: [off, me]).isEmpty)
    }

    func testSavingRefusesAnOverlapAndChangesNothing() {
        let work = alarm("Work", days: [2, 3, 4])
        let book = SmartWakeAlarmBook(alarms: [work])
        let clash = alarm("Clash", days: [4, 5])
        guard case let .conflicts(list) = book.saving(clash) else { return XCTFail("expected a conflict") }
        XCTAssertEqual(list.map(\.alarmID), [work.id])
        // A disabled copy is fine: it rings on nothing.
        var asleep = clash
        asleep.isEnabled = false
        guard case .applied = book.saving(asleep) else { return XCTFail("a disabled alarm cannot conflict") }
    }

    func testForcingSwitchesTheOtherAlarmOffInsteadOfDeletingIt() {
        let work = alarm("Work", days: [2, 3, 4])
        let clash = alarm("Clash", days: [4, 5])
        let next = SmartWakeAlarmBook(alarms: [work]).forcing(clash)
        XCTAssertEqual(next.alarms.count, 2)
        XCTAssertFalse(next.alarms.first { $0.id == work.id }!.isEnabled)
        XCTAssertTrue(next.alarms.first { $0.id == clash.id }!.isEnabled)
        XCTAssertTrue(next.doubleBookedDays().isEmpty)
    }

    func testAnAlarmWithoutWeekdaysIsRefused() {
        let none = SmartWakeAlarm(weekdays: [])
        XCTAssertEqual(SmartWakeAlarmBook().saving(none), .needsWeekday)
    }

    // fork: at most five alarms.

    private func fullBook() -> SmartWakeAlarmBook {
        SmartWakeAlarmBook(alarms: (1...5).map { alarm("A\($0)", days: [$0]) })
    }

    func testASixthAlarmIsRefused() {
        let book = fullBook()
        XCTAssertEqual(SmartWakeAlarmBook.maxAlarms, 5)
        XCTAssertFalse(book.canAdd)
        XCTAssertEqual(book.saving(alarm("Sixth", days: [6])), .limitReached)
    }

    func testTheFifthAlarmIsAccepted() {
        let four = SmartWakeAlarmBook(alarms: (1...4).map { alarm("A\($0)", days: [$0]) })
        XCTAssertTrue(four.canAdd)
        guard case let .applied(next) = four.saving(alarm("Fifth", days: [5])) else { return XCTFail("refused") }
        XCTAssertEqual(next.alarms.count, 5)
    }

    func testEditingAnAlarmAtTheLimitIsStillAccepted() {
        let book = fullBook()
        var changed = book.alarms[0]
        changed.wakeMinutes = 8 * 60
        guard case let .applied(next) = book.saving(changed) else { return XCTFail("an edit is not an addition") }
        XCTAssertEqual(next.alarms.count, 5)
        XCTAssertEqual(next.alarms[0].wakeMinutes, 8 * 60)
    }

    func testDeletingAtTheLimitFreesASlot() {
        let book = fullBook()
        XCTAssertTrue(book.deleting(id: book.alarms[0].id).canAdd)
    }

    func testAListStoredWithMoreThanFiveKeepsThemAndRefusesMore() {
        let big = SmartWakeAlarmBook(alarms: (1...7).map { alarm("A\($0)", days: [$0]) })
        XCTAssertEqual(big.alarms.count, 7)
        XCTAssertEqual(big.saving(alarm("More", days: [])), .needsWeekday, "weekday check comes first")
        XCTAssertFalse(big.canAdd)
    }

    func testDeletingRemovesOnlyThatAlarm() {
        let a = alarm("A", days: [2]), b = alarm("B", days: [3])
        XCTAssertEqual(SmartWakeAlarmBook(alarms: [a, b]).deleting(id: a.id).alarms.map(\.label), ["B"])
    }

    // MARK: Migration

    func testMigrationKeepsDaysTimesWindowAndInsistence() {
        let book = SmartWakeAlarmMigration.make(minutes: 7 * 60 + 20, weekdays: [2, 3, 4, 5, 6], overrides: [6: 9 * 60, 1: 600],
                                                windowMinutes: 45, insistent: true)
        XCTAssertEqual(book.alarms.count, 1)
        let a = book.alarms[0]
        XCTAssertTrue(a.isEnabled)
        XCTAssertEqual(a.label, "")
        XCTAssertEqual(a.weekdays, [2, 3, 4, 5, 6])
        XCTAssertEqual(a.dayOverrides, [6: 9 * 60])   // Sunday is not an alarm day, its override stays upstream
        XCTAssertEqual(a.windowMinutes, 45)
        XCTAssertTrue(a.insistent)
        let days = book.effectiveDays()
        XCTAssertEqual(days[6]?.minutes, 9 * 60)
        XCTAssertEqual(days[2]?.minutes, 7 * 60 + 20)
        XCTAssertNil(days[1])
    }

    func testEmptyUpstreamWeekdaysMeanEveryDay() {
        let book = SmartWakeAlarmMigration.make(minutes: 420, weekdays: [], overrides: [:], windowMinutes: 30, insistent: false)
        XCTAssertEqual(book.alarms[0].weekdays, Set(1...7))
        XCTAssertEqual(Set(book.effectiveDays().keys), Set(1...7))
    }

    func testMigrationMatchesTheScheduleBuiltFromTheSameSettings() {
        // The grid the single schedule can be in: every day / weekdays, with and without overrides.
        let cases: [(Set<Int>, [Int: Int])] = [
            ([], [:]), ([2, 3, 4, 5, 6], [:]), ([], [7: 600, 1: 660]),
            ([2, 3, 4, 5, 6], [6: 500, 7: 600]), ([4], [4: 420]),
        ]
        for (weekdays, overrides) in cases {
            let book = SmartWakeAlarmMigration.make(minutes: 400, weekdays: weekdays, overrides: overrides,
                                                    windowMinutes: 30, insistent: false)
            let effective = book.effectiveDays()
            let expectedDays = weekdays.isEmpty ? Set(1...7) : weekdays
            XCTAssertEqual(Set(effective.keys), expectedDays)
            for day in expectedDays {
                XCTAssertEqual(effective[day]?.minutes, overrides[day] ?? 400, "weekday \(day)")
            }
        }
    }

    // MARK: Storage

    func testRoundTripThroughDefaultsIsStable() {
        let defaults = makeDefaults()
        var work = alarm("Work", days: [2, 3, 4], age: 0.25)
        work.dayOverrides = [3: 8 * 60, 2: 7 * 60]
        let book = SmartWakeAlarmBook(alarms: [work, alarm("Other", days: [5, 6], age: 40)])
        XCTAssertTrue(SmartWakeAlarmBookStorage.save(book, defaults: defaults))   // first write creates the key

        guard case let .book(loaded) = SmartWakeAlarmBookStorage.load(defaults: defaults) else { return XCTFail("not loaded") }
        XCTAssertEqual(loaded, book)
        // createdAt is whole seconds (0.25 s was rounded down on creation) and survives the round trip exactly.
        XCTAssertEqual(book.alarms[0].createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(loaded.alarms[0].createdAt, book.alarms[0].createdAt)

        // load -> save -> save: neither save writes, and createdAt is unchanged after each.
        XCTAssertFalse(SmartWakeAlarmBookStorage.save(loaded, defaults: defaults))
        guard case let .book(second) = SmartWakeAlarmBookStorage.load(defaults: defaults) else { return XCTFail("not loaded") }
        XCTAssertEqual(second.alarms.map(\.createdAt), book.alarms.map(\.createdAt))
        XCTAssertFalse(SmartWakeAlarmBookStorage.save(second, defaults: defaults))
        XCTAssertEqual(SmartWakeAlarmBookStorage.load(defaults: defaults), .book(book))
    }

    func testSanitizingRoundsCreatedAtDownToTheSecond() {
        let a = SmartWakeAlarm(createdAt: Date(timeIntervalSince1970: 1_700_000_000.999))
        XCTAssertEqual(a.createdAt.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(a.sanitized().createdAt, a.createdAt)   // idempotent
    }

    func testEncodingIsDeterministicEvenWithManyOverrides() {
        var a = alarm("A", days: Set(1...7))
        a.dayOverrides = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 300 + $0) })
        let first = SmartWakeAlarmBookStorage.encode(SmartWakeAlarmBook(alarms: [a]))
        for _ in 0..<20 { XCTAssertEqual(SmartWakeAlarmBookStorage.encode(SmartWakeAlarmBook(alarms: [a])), first) }
    }

    func testAbsentKeyLoadsAsAbsent() {
        XCTAssertEqual(SmartWakeAlarmBookStorage.load(defaults: makeDefaults()), .absent)
    }

    func testCorruptBlobIsPreservedAndReportedUnreadable() {
        let defaults = makeDefaults()
        let junk = Data("not json".utf8)
        defaults.set(junk, forKey: SmartWakeAlarmBookStorage.key)
        XCTAssertEqual(SmartWakeAlarmBookStorage.load(defaults: defaults), .unreadable)
        XCTAssertEqual(defaults.data(forKey: SmartWakeAlarmBookStorage.corruptKey), junk)
        XCTAssertNil(defaults.data(forKey: SmartWakeAlarmBookStorage.key))
    }

    func testANewerVersionIsNotReadAsCurrent() throws {
        let defaults = makeDefaults()
        let future = SmartWakeAlarmBook(version: 2, alarms: [alarm("A", days: [2])])
        defaults.set(try XCTUnwrap(SmartWakeAlarmBookStorage.encode(future)), forKey: SmartWakeAlarmBookStorage.key)
        XCTAssertEqual(SmartWakeAlarmBookStorage.load(defaults: defaults), .unreadable)
        XCTAssertNotNil(defaults.data(forKey: SmartWakeAlarmBookStorage.corruptKey))
    }

    func testSnapshotBytesAreDeterministicAndRoundTrip() throws {
        let defaults = makeDefaults()
        let snapshot = SmartWakeAlarmMigration.UpstreamSnapshot(minutes: 440, weekdays: [6, 2, 4], overrides: [7: 600, 1: 660, 3: 500])
        SmartWakeAlarmBookStorage.saveSnapshot(snapshot, defaults: defaults)
        let first = defaults.data(forKey: SmartWakeAlarmBookStorage.preMigrationKey)
        for _ in 0..<10 { SmartWakeAlarmBookStorage.saveSnapshot(snapshot, defaults: defaults) }
        XCTAssertEqual(defaults.data(forKey: SmartWakeAlarmBookStorage.preMigrationKey), first)
        XCTAssertEqual(SmartWakeAlarmBookStorage.loadSnapshot(defaults: defaults), snapshot)
        XCTAssertEqual(snapshot.weekdays, [2, 4, 6])
    }

    func testDiagnosticLinesListEveryAlarmAndWarnAboutADoubleBookedDay() {
        let work = SmartWakeAlarm(label: "Work", wakeMinutes: 7 * 60, weekdays: [2, 3], windowMinutes: 30, insistent: true,
                                  createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let other = SmartWakeAlarm(label: "", wakeMinutes: 8 * 60, weekdays: [3], windowMinutes: 20,
                                   createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let lines = SmartWakeAlarmBook(alarms: [work, other]).diagnosticLines()
        XCTAssertEqual(lines.first, "Alarm list: 2 alarm(s), 2 on")
        XCTAssertTrue(lines.contains { $0.contains("07:00") && $0.contains("\"Work\"") && $0.contains("insistent") })
        XCTAssertTrue(lines.contains { $0.contains("(no label)") && $0.contains("window 20 min") })
        XCTAssertTrue(lines.contains { $0.contains("WARNING") && $0.contains("3") })
        XCTAssertFalse(SmartWakeAlarmBook(alarms: [work]).diagnosticLines().contains { $0.contains("WARNING") })
    }

    func testMirroredValuesDifferOnlyWhenTheUpstreamSettingsMoved() {
        let snapshot = SmartWakeAlarmMigration.UpstreamSnapshot(minutes: 420, weekdays: [], overrides: [7: 600])
        func differ(_ minutes: Int, _ weekdays: Set<Int>, _ overrides: [Int: Int]) -> Bool {
            SmartWakeAlarmMigration.mirroredValuesDiffer(snapshot: snapshot, minutes: minutes, weekdays: weekdays, overrides: overrides)
        }
        XCTAssertFalse(differ(420, [], [7: 600]))
        XCTAssertFalse(differ(420, Set(1...7), [7: 600]), "every day, in either spelling")
        XCTAssertTrue(differ(430, [], [7: 600]))
        XCTAssertTrue(differ(420, [2, 3], [7: 600]))
        XCTAssertTrue(differ(420, [], [:]))
        XCTAssertFalse(SmartWakeAlarmMigration.mirroredValuesDiffer(snapshot: nil, minutes: 1, weekdays: [2], overrides: [:]))
    }
}
