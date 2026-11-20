import XCTest
@testable import Strand

/// The pure half of "the alarm list owns the schedule": list -> schedule, list -> upstream settings, saved schedule ->
/// what AlarmKit has to do, who owns the strap alarm. Nothing here talks to AlarmKit or the strap.
final class SmartWakeAlarmCompileTests: XCTestCase {
    // MARK: Helpers

    private func rome() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SmartWakeAlarmCompileTests.\(UUID().uuidString)")!
    }

    /// The same one-liner the iOS wiring uses to hand the list to `SmartWakeSchedule.compiled`.
    private func specs(_ book: SmartWakeAlarmBook) -> [Int: SmartWakeDaySpec] {
        book.effectiveDays().mapValues {
            SmartWakeDaySpec(minutes: $0.minutes, windowMinutes: $0.windowMinutes, label: $0.label, insistent: $0.insistent)
        }
    }

    private func minutes(_ book: SmartWakeAlarmBook) -> [Int: Int] { book.effectiveDays().mapValues(\.minutes) }

    private func alarm(_ label: String = "", days: Set<Int>, minutes: Int, window: Int = 30, insistent: Bool = false,
                       enabled: Bool = true, age: TimeInterval = 0) -> SmartWakeAlarm {
        SmartWakeAlarm(label: label, isEnabled: enabled, wakeMinutes: minutes, weekdays: days, windowMinutes: window,
                       insistent: insistent, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + age))
    }

    private struct Case {
        let weekdays: Set<Int>
        let overrides: [Int: Int]
    }

    /// The configurations the single schedule can be in today.
    private let grid: [Case] = [
        Case(weekdays: [], overrides: [:]),
        Case(weekdays: Set(1...7), overrides: [:]),
        Case(weekdays: [2, 3, 4, 5, 6], overrides: [:]),
        Case(weekdays: [], overrides: [7: 600, 1: 660]),
        Case(weekdays: [2, 3, 4, 5, 6], overrides: [6: 500, 7: 600]),
        Case(weekdays: [2, 3, 4, 5, 6], overrides: [3: 400]),       // an override equal to the base
        Case(weekdays: [4], overrides: [4: 420]),                    // the only day has its own time
        Case(weekdays: [2, 3], overrides: [2: 500, 3: 500]),         // every active day overridden
    ]
    private let baseMinutes = 400

    private func legacySettings(_ c: Case) -> SmartWakeUpstreamSettings {
        SmartWakeUpstreamSettings(minutes: baseMinutes, weekdays: c.weekdays, overrides: c.overrides)
    }

    /// What `SmartWakeLiveWiring.makeSchedule` builds today from the same settings.
    private func legacySchedule(_ c: Case, window: Int = 30) -> SmartWakeSchedule {
        SmartWakeSchedule(wakeMinutes: baseMinutes, weekdays: c.weekdays, overrides: c.overrides,
                          windowDuration: TimeInterval(window * 60))
    }

    private func migrated(_ c: Case, window: Int = 30, insistent: Bool = false) -> SmartWakeAlarmBook {
        SmartWakeAlarmMigration.make(minutes: baseMinutes, weekdays: c.weekdays, overrides: c.overrides,
                                     windowMinutes: window, insistent: insistent)
    }

    /// An upstream store backed by a dedicated suite: every setter writes a key there, so a write cannot go unseen.
    private final class SuiteStore: SmartWakeUpstreamStore {
        static let prefix = "test.upstream."
        let defaults: UserDefaults
        private var current: SmartWakeUpstreamSettings
        private(set) var writes: [String] = []
        /// Called after every write, the way a SwiftUI `onChange` of the written value would be.
        var onWrite: (() -> Void)?

        init(_ settings: SmartWakeUpstreamSettings, defaults: UserDefaults) {
            current = settings
            self.defaults = defaults
        }

        var settings: SmartWakeUpstreamSettings { current }
        var keysInSuite: [String] { defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.prefix) }.sorted() }

        func setMinutes(_ minutes: Int) {
            current.minutes = minutes
            defaults.set(minutes, forKey: Self.prefix + "minutes")
            writes.append("minutes"); onWrite?()
        }

        func setWeekdays(_ weekdays: Set<Int>) {
            current.weekdays = weekdays
            defaults.set(weekdays.sorted(), forKey: Self.prefix + "weekdays")
            writes.append("weekdays"); onWrite?()
        }

        func setOverride(weekday: Int, minutes: Int?) {
            if let minutes { current.overrides[weekday] = minutes } else { current.overrides.removeValue(forKey: weekday) }
            defaults.set(minutes ?? -1, forKey: Self.prefix + "override.\(weekday)")
            writes.append("override.\(weekday)"); onWrite?()
        }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    /// The hold's timer, driven by hand: `fireAll` runs what was scheduled, the way the main queue would at the deadline.
    private final class ManualScheduler {
        private var pending: [() -> Void] = []
        var scheduledCount: Int { pending.count }
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { pending.append(work) }
        func fireAll() {
            let work = pending
            pending = []
            work.forEach { $0() }
        }
    }

    // MARK: 1. Migration -> compiled schedule

    func testMigrationCompilesToTheScheduleTodayBuilds() throws {
        for c in grid {
            let compiled = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(migrated(c))), "\(c)")
            let legacy = legacySchedule(c)
            XCTAssertEqual(compiled.alarmProjection, legacy.alarmProjection, "\(c)")
            for day in 1...7 {
                XCTAssertEqual(compiled.isEnabled(onWeekday: day), legacy.isEnabled(onWeekday: day), "\(c) day \(day)")
            }
            XCTAssertEqual(compiled.windowDuration, legacy.windowDuration, "\(c)")
        }
    }

    func testMigrationLeavesTheOptionalPerDayDataEmptyWhenThereIsNothingToSay() throws {
        for c in grid {
            let compiled = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(migrated(c, window: 45))))
            XCTAssertTrue(compiled.windowOverrides.isEmpty, "every day has the base window: \(c)")
            XCTAssertEqual(compiled.windowDuration, 45 * 60)
            XCTAssertTrue(compiled.labels.isEmpty, "the migrated alarm has no label: \(c)")
            XCTAssertTrue(compiled.insistentDays.isEmpty, "not insistent: \(c)")
        }
    }

    func testBaseIsTheMostFrequentTimeAndOnlyTheOtherDaysAreOverrides() throws {
        let book = SmartWakeAlarmBook(alarms: [
            alarm("Work", days: [2, 3, 4], minutes: 6 * 60 + 45),
            alarm("Other", days: [5, 6], minutes: 7 * 60 + 30),
        ])
        let s = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(book)))
        XCTAssertEqual(s.wakeMinutes, 6 * 60 + 45)
        XCTAssertEqual(s.overrides, [5: 7 * 60 + 30, 6: 7 * 60 + 30])
        XCTAssertEqual(s.weekdays, [2, 3, 4, 5, 6])
        XCTAssertEqual(s.labels, [2: "Work", 3: "Work", 4: "Work", 5: "Other", 6: "Other"])
    }

    func testATieGoesToTheEarlierTimeAndTheShorterWindow() throws {
        let book = SmartWakeAlarmBook(alarms: [
            alarm(days: [2, 3], minutes: 8 * 60, window: 45),
            alarm(days: [4, 5], minutes: 6 * 60, window: 15),
        ])
        let s = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(book)))
        XCTAssertEqual(s.wakeMinutes, 6 * 60)
        XCTAssertEqual(s.overrides, [2: 8 * 60, 3: 8 * 60])
        XCTAssertEqual(s.windowDuration, 15 * 60)
        XCTAssertEqual(s.windowOverrides, [2: 45 * 60, 3: 45 * 60])
    }

    func testWindowLabelAndInsistenceAreRecordedOnlyWhereTheyDiffer() throws {
        let book = SmartWakeAlarmBook(alarms: [
            alarm("Work", days: [2, 3, 4], minutes: 420, window: 30, insistent: true),
            alarm(days: [5, 6], minutes: 420, window: 20),
        ])
        let s = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(book)))
        XCTAssertEqual(s.windowDuration, 30 * 60)
        XCTAssertEqual(s.windowOverrides, [5: 20 * 60, 6: 20 * 60])
        XCTAssertEqual(s.labels, [2: "Work", 3: "Work", 4: "Work"])
        XCTAssertEqual(s.insistentDays, [2, 3, 4])
        XCTAssertTrue(s.overrides.isEmpty)
    }

    // MARK: 5. No active alarm -> nil, never an empty weekday set

    func testNoActiveAlarmCompilesToNilNeverToAnEveryDaySchedule() {
        XCTAssertNil(SmartWakeSchedule.compiled(days: [:]))
        XCTAssertNil(SmartWakeSchedule.compiled(days: specs(SmartWakeAlarmBook())))
        let allOff = SmartWakeAlarmBook(alarms: [alarm(days: [2, 3], minutes: 420, enabled: false),
                                                 alarm(days: [5], minutes: 500, enabled: false)])
        XCTAssertNil(SmartWakeSchedule.compiled(days: specs(allOff)))
        XCTAssertNil(SmartWakeSchedule.compiled(days: [0: SmartWakeDaySpec(minutes: 420), 9: SmartWakeDaySpec(minutes: 420)]))
    }

    func testAScheduleWithADaySubsetNeverHasAnEmptyWeekdaySet() throws {
        for days: Set<Int> in [[1], [2, 3], [1, 2, 3, 4, 5, 6]] {
            let s = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(SmartWakeAlarmBook(alarms: [alarm(days: days, minutes: 420)]))))
            XCTAssertEqual(s.weekdays, days)
            XCTAssertEqual(Set(s.alarmProjection.keys), days)
        }
        // Seven days is the one case spelled with the empty set: it is how "every day" has always been stored.
        let all = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(SmartWakeAlarmBook(alarms: [alarm(days: Set(1...7), minutes: 420)]))))
        XCTAssertTrue(all.weekdays.isEmpty)
        XCTAssertEqual(Set(all.alarmProjection.keys), Set(1...7))
    }

    // MARK: 2. Migration -> mirror: zero writes

    func testMirroringAMigratedConfigurationWritesNothing() {
        for c in grid {
            let defaults = makeDefaults()
            let store = SuiteStore(legacySettings(c), defaults: defaults)
            let hold = SmartWakeArmHold()
            let changes = SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(migrated(c)), to: store, hold: hold)
            XCTAssertTrue(changes.isEmpty, "\(c): \(changes)")
            XCTAssertEqual(store.writes, [], "\(c)")
            XCTAssertEqual(store.keysInSuite, [], "no key reached the suite: \(c)")
            XCTAssertEqual(store.settings, legacySettings(c), "\(c)")
            XCTAssertFalse(hold.isHolding, "nothing written, so nothing to hold: \(c)")
            XCTAssertFalse(hold.finish(), "nothing was begun, so nothing is owed: \(c)")
        }
    }

    func testTheUpstreamStoreStaysUntouchedAcrossMigrationMirrorAndAReload() {
        let defaults = makeDefaults()
        let store = SuiteStore(legacySettings(grid[4]), defaults: defaults)
        let book = SmartWakeAlarmBookMigrator.loadOrMigrate(upstream: {
            .init(minutes: self.baseMinutes, weekdays: self.grid[4].weekdays, overrides: self.grid[4].overrides,
                  windowMinutes: 30, insistent: false)
        }, defaults: defaults).book
        // Two more passes, as the next foregrounds would make.
        for _ in 0..<2 { SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(book), to: store) }
        XCTAssertEqual(store.writes, [])
        XCTAssertEqual(store.keysInSuite, [])
    }

    // MARK: Mirror: what it does write

    func testChangingTheOnlyAlarmsTimeMovesTheBaseInsteadOfFillingEveryDayWithAnOverride() {
        let defaults = makeDefaults()
        let store = SuiteStore(.init(minutes: 420, weekdays: [2, 3, 4, 5, 6], overrides: [:]), defaults: defaults)
        let book = SmartWakeAlarmBook(alarms: [alarm(days: [2, 3, 4, 5, 6], minutes: 480)])
        let changes = SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(book), to: store)
        XCTAssertEqual(changes.minutes, 480)
        XCTAssertNil(changes.weekdays)
        XCTAssertTrue(changes.overrideSets.isEmpty && changes.overrideClears.isEmpty)
        XCTAssertEqual(store.writes, ["minutes"])
    }

    func testTwoAlarmsKeepTheBaseAndOverrideTheOtherAlarmsDays() {
        let defaults = makeDefaults()
        let store = SuiteStore(.init(minutes: 405, weekdays: [2, 3, 4, 5, 6], overrides: [:]), defaults: defaults)
        let book = SmartWakeAlarmBook(alarms: [alarm("Work", days: [2, 3, 4], minutes: 405),
                                               alarm("Other", days: [5, 6], minutes: 450)])
        let changes = SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(book), to: store)
        XCTAssertNil(changes.minutes)
        XCTAssertEqual(changes.overrideSets, [5: 450, 6: 450])
        XCTAssertEqual(store.settings.overrides, [5: 450, 6: 450])
    }

    func testWeekdaysAreTheUnionOfTheActiveDays() {
        let store = SuiteStore(.init(minutes: 420, weekdays: [], overrides: [:]), defaults: makeDefaults())
        let book = SmartWakeAlarmBook(alarms: [alarm(days: [2, 3, 4], minutes: 420), alarm(days: [6], minutes: 420)])
        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(book), to: store)
        XCTAssertEqual(store.settings.weekdays, [2, 3, 4, 6])
    }

    func testEverySpellingOfEveryDayIsLeftAlone() {
        let allDays = SmartWakeAlarmBook(alarms: [alarm(days: Set(1...7), minutes: 420)])
        for spelling: Set<Int> in [[], Set(1...7)] {
            let store = SuiteStore(.init(minutes: 420, weekdays: spelling, overrides: [:]), defaults: makeDefaults())
            XCTAssertTrue(SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(allDays), to: store).isEmpty)
        }
        // A subset that grows to seven days is written as the canonical empty set.
        let store = SuiteStore(.init(minutes: 420, weekdays: [2, 3], overrides: [:]), defaults: makeDefaults())
        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(allDays), to: store)
        XCTAssertEqual(store.settings.weekdays, [])
    }

    func testOverridesOfDaysWithoutAnAlarmSurviveBecauseTheEveningReminderReadsThem() {
        let store = SuiteStore(.init(minutes: 420, weekdays: [2, 3], overrides: [7: 600]), defaults: makeDefaults())
        let book = SmartWakeAlarmBook(alarms: [alarm(days: [2, 3], minutes: 420)])
        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(book), to: store)
        XCTAssertEqual(store.settings.overrides, [7: 600])
    }

    func testAnOverrideThatNoLongerDiffersFromTheBaseIsCleared() {
        let store = SuiteStore(.init(minutes: 420, weekdays: [2, 3], overrides: [3: 500]), defaults: makeDefaults())
        let book = SmartWakeAlarmBook(alarms: [alarm(days: [2, 3], minutes: 420)])
        let changes = SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(book), to: store)
        XCTAssertEqual(changes.overrideClears, [3])
        XCTAssertEqual(store.settings.overrides, [:])
    }

    func testNoActiveAlarmLeavesTheUpstreamSettingsAsTheyAre() {
        let current = SmartWakeUpstreamSettings(minutes: 420, weekdays: [2, 3], overrides: [3: 500])
        let store = SuiteStore(current, defaults: makeDefaults())
        XCTAssertTrue(SmartWakeUpstreamMirror.apply(effectiveMinutes: [:], to: store).isEmpty)
        XCTAssertEqual(store.settings, current)
        XCTAssertEqual(store.writes, [])
    }

    // MARK: Arm hold: N mirror writes, exactly one arm

    /// Two alarms against a single weekday alarm: the mirror has to write the base time, the weekdays and two overrides.
    private func manyWritesBook() -> SmartWakeAlarmBook {
        SmartWakeAlarmBook(alarms: [alarm("Work", days: [2, 3], minutes: 360), alarm("Other", days: [5, 6, 7], minutes: 540)])
    }

    private let manyWritesStart = SmartWakeUpstreamSettings(minutes: 420, weekdays: [2, 3, 4, 5, 6], overrides: [:])

    func testBeginThreeWritesFinishThenThreeEchoesIsOneArmInTotal() {
        let clock = Clock()
        let scheduler = ManualScheduler()
        let hold = SmartWakeArmHold(window: 1.5, now: { clock.now }, schedule: scheduler.schedule)
        let store = SuiteStore(manyWritesStart, defaults: makeDefaults())
        var arms = 0
        var armedWith: SmartWakeUpstreamSettings?
        // What the top of `AppModel.applySmartAlarm()` does: ask the hold, and arm only when it lets the call through.
        func applySmartAlarm() { if !hold.swallows() { arms += 1; armedWith = store.settings } }
        store.onWrite = { applySmartAlarm() }   // the Alarms screen's onChange of each written value

        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(manyWritesBook()), to: store, hold: hold, arm: { applySmartAlarm() })
        XCTAssertGreaterThanOrEqual(store.writes.count, 3, "the change really is several writes: \(store.writes)")
        XCTAssertEqual(arms, 0, "requests during the writes are swallowed: none arms a half-written configuration")

        XCTAssertTrue(hold.finish())
        XCTAssertEqual(arms, 1, "finish arms now, once (the arm itself is not swallowed)")
        let final = SmartWakeUpstreamMirror.target(current: manyWritesStart, effectiveMinutes: minutes(manyWritesBook()))
        XCTAssertEqual(armedWith, final, "and it read the complete configuration")
        XCTAssertEqual(store.settings, final)

        clock.now.addTimeInterval(0.2)   // the echoes arrive one render pass after the writes, inside the window
        for _ in 0..<3 { applySmartAlarm() }
        XCTAssertEqual(arms, 1, "the window is still open after finish: the echoes are ignored")

        XCTAssertFalse(hold.finish(), "a second finish has nothing owed")
        clock.now.addTimeInterval(2)
        scheduler.fireAll()              // the timer finds nothing owed
        XCTAssertEqual(arms, 1)
        XCTAssertFalse(hold.isHolding)
        applySmartAlarm()
        XCTAssertEqual(arms, 2, "after the window an ordinary request goes through")
    }

    func testAWindowThatEndsWithoutFinishStillArmsExactlyOnceOnTheCompleteConfiguration() {
        let clock = Clock()
        let scheduler = ManualScheduler()
        let hold = SmartWakeArmHold(window: 1.5, now: { clock.now }, schedule: scheduler.schedule)
        let store = SuiteStore(manyWritesStart, defaults: makeDefaults())
        var arms = 0
        var armedWith: SmartWakeUpstreamSettings?
        func applySmartAlarm() { if !hold.swallows() { arms += 1; armedWith = store.settings } }
        store.onWrite = { applySmartAlarm() }

        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(manyWritesBook()), to: store, hold: hold, arm: { applySmartAlarm() })
        XCTAssertEqual(scheduler.scheduledCount, 1, "the timer is scheduled when the hold begins")
        XCTAssertEqual(arms, 0)

        // No finish, and no new applySmartAlarm either: only the timer can arm.
        clock.now.addTimeInterval(1.5)
        scheduler.fireAll()
        XCTAssertEqual(arms, 1)
        XCTAssertEqual(armedWith, SmartWakeUpstreamMirror.target(current: manyWritesStart, effectiveMinutes: minutes(manyWritesBook())))
        scheduler.fireAll()
        XCTAssertEqual(arms, 1, "exactly one")
        XCTAssertFalse(hold.isHolding)
    }

    func testARealChangeInsideTheWindowIsNeverSwallowed() {
        let clock = Clock()
        let scheduler = ManualScheduler()
        let hold = SmartWakeArmHold(window: 1.5, now: { clock.now }, schedule: scheduler.schedule)
        let store = SuiteStore(manyWritesStart, defaults: makeDefaults())
        var arms = 0
        var armedWith: SmartWakeUpstreamSettings?
        func applySmartAlarm() { if !hold.swallows() { arms += 1; armedWith = store.settings } }
        store.onWrite = { applySmartAlarm() }

        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(manyWritesBook()), to: store, hold: hold, arm: { applySmartAlarm() })
        hold.finish()
        XCTAssertEqual(arms, 1)
        clock.now.addTimeInterval(0.2)
        applySmartAlarm()                // an echo
        XCTAssertEqual(arms, 1)

        // The user edits something inside the window. Its arm request finds settings the last arm did not read.
        store.setMinutes(store.settings.minutes + 30)
        XCTAssertEqual(arms, 2, "not swallowed")
        XCTAssertEqual(armedWith?.minutes, store.settings.minutes, "and armed with the new value")
    }

    func testSwallowedRequestsEndInOneArmWhenSeveralBurstsShareAWindow() {
        let clock = Clock()
        let scheduler = ManualScheduler()
        let hold = SmartWakeArmHold(window: 1.5, now: { clock.now }, schedule: scheduler.schedule)
        let store = SuiteStore(.init(minutes: 420, weekdays: [2, 3, 4, 5, 6], overrides: [:]), defaults: makeDefaults())
        var arms = 0
        func applySmartAlarm() { if !hold.swallows() { arms += 1 } }
        store.onWrite = { applySmartAlarm() }
        for start in [360, 380, 400] {
            SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(SmartWakeAlarmBook(alarms: [alarm(days: [2, 3, 4, 5, 6], minutes: start)])),
                                          to: store, hold: hold, arm: { applySmartAlarm() })
            clock.now.addTimeInterval(0.3)
        }
        XCTAssertEqual(arms, 0)
        hold.finish()
        XCTAssertEqual(arms, 1)
        clock.now.addTimeInterval(2)
        scheduler.fireAll()              // three timers, two of them superseded, none owes anything
        XCTAssertEqual(arms, 1)
    }

    func testALateTimerAfterSuspensionDoesNotArmTwice() {
        let clock = Clock()
        let scheduler = ManualScheduler()
        let hold = SmartWakeArmHold(window: 1.5, now: { clock.now }, schedule: scheduler.schedule)
        let store = SuiteStore(manyWritesStart, defaults: makeDefaults())
        var arms = 0
        func applySmartAlarm() { if !hold.swallows() { arms += 1 } }
        store.onWrite = { applySmartAlarm() }
        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(manyWritesBook()), to: store, hold: hold, arm: { applySmartAlarm() })
        XCTAssertEqual(arms, 0)

        // The app is suspended: the window passes and the timer does not run. The foreground's own applySmartAlarm
        // arrives first, goes through, and is the owed arm.
        clock.now.addTimeInterval(60)
        applySmartAlarm()
        XCTAssertEqual(arms, 1)
        scheduler.fireAll()              // the late timer finds the hold already settled
        XCTAssertEqual(arms, 1)
    }

    func testWithoutAHoldEveryWriteArmsThatIsTheProblemTheHoldSolves() {
        let store = SuiteStore(manyWritesStart, defaults: makeDefaults())
        var arms = 0
        store.onWrite = { arms += 1 }
        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(manyWritesBook()), to: store)
        XCTAssertEqual(arms, store.writes.count)
        XCTAssertGreaterThan(arms, 1)
    }

    func testAMirrorWithNothingToWriteOpensNoHoldAndArmsNothing() {
        let scheduler = ManualScheduler()
        let hold = SmartWakeArmHold(window: 1.5, schedule: scheduler.schedule)
        let store = SuiteStore(manyWritesStart, defaults: makeDefaults())
        let same = SmartWakeAlarmBook(alarms: [alarm(days: [2, 3, 4, 5, 6], minutes: 420)])
        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(same), to: store, hold: hold, arm: { XCTFail("must not arm") })
        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertFalse(hold.isHolding)
        XCTAssertFalse(hold.swallows())
        XCTAssertFalse(hold.finish())
    }

    // MARK: 3. Sync plan: what AlarmKit is asked to do

    func testMigrationNeverAsksAlarmKitForAnything() throws {
        for c in grid {
            let compiled = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(migrated(c))))
            let plan = SmartWakeSyncPlan.make(previous: legacySchedule(c), next: compiled, osChanged: false)
            XCTAssertTrue(plan.installDays.isEmpty && plan.removeDays.isEmpty, "\(c): \(plan)")
            XCTAssertTrue(plan == .nothing || plan == .metadataOnly, "\(c): \(plan)")
        }
    }

    func testAnUnchangedConfigurationIsExactlyNothingToDo() throws {
        let c = grid[0]
        let compiled = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(migrated(c))))
        XCTAssertEqual(compiled, legacySchedule(c))
        XCTAssertEqual(SmartWakeSyncPlan.make(previous: legacySchedule(c), next: compiled, osChanged: false), .nothing)
    }

    func testAnInsistentMigratedAlarmChangesTheSavedScheduleOnceAndOnlyAsMetadata() throws {
        for c in grid {
            let compiled = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(migrated(c, insistent: true))))
            XCTAssertFalse(compiled.insistentDays.isEmpty, "\(c)")
            let first = SmartWakeSyncPlan.make(previous: legacySchedule(c), next: compiled, osChanged: false)
            XCTAssertEqual(first, .metadataOnly, "\(c)")
            XCTAssertTrue(first.installDays.isEmpty && first.removeDays.isEmpty, "zero AlarmKit calls: \(c)")
            // The scheduler saves `compiled`; the next sync finds it equal.
            XCTAssertEqual(SmartWakeSyncPlan.make(previous: compiled, next: compiled, osChanged: false), .nothing, "\(c)")
        }
    }

    func testChangingOneDaysTimeReinstallsOnlyThatDay() throws {
        let before = SmartWakeAlarmBook(alarms: [alarm("Work", days: [2, 3, 4], minutes: 405), alarm("Other", days: [5, 6], minutes: 450)])
        let after = SmartWakeAlarmBook(alarms: [alarm("Work", days: [2, 3, 4], minutes: 405), alarm("Other", days: [5, 6], minutes: 465)])
        let plan = SmartWakeSyncPlan.make(previous: SmartWakeSchedule.compiled(days: specs(before)),
                                          next: try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(after))), osChanged: false)
        XCTAssertEqual(plan, .alarms(install: [5, 6], remove: []))
    }

    func testRemovingADayCancelsOnlyThatDay() throws {
        let before = SmartWakeAlarmBook(alarms: [alarm(days: [2, 3, 4], minutes: 405)])
        let after = SmartWakeAlarmBook(alarms: [alarm(days: [2, 3], minutes: 405)])
        let plan = SmartWakeSyncPlan.make(previous: SmartWakeSchedule.compiled(days: specs(before)),
                                          next: try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(after))), osChanged: false)
        XCTAssertEqual(plan, .alarms(install: [], remove: [4]))
    }

    func testMovingADayBetweenAlarmsReinstallsThatDayAndNothingElse() throws {
        let work = alarm("Work", days: [2, 3, 4], minutes: 405)
        let other = alarm("Other", days: [5, 6], minutes: 450)
        var movedWork = work; movedWork.weekdays = [2, 3]
        var movedOther = other; movedOther.weekdays = [4, 5, 6]; movedOther.wakeMinutes = 450
        let plan = SmartWakeSyncPlan.make(previous: SmartWakeSchedule.compiled(days: specs(SmartWakeAlarmBook(alarms: [work, other]))),
                                          next: try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(SmartWakeAlarmBook(alarms: [movedWork, movedOther])))),
                                          osChanged: false)
        XCTAssertEqual(plan, .alarms(install: [4], remove: []), "Wednesday goes from Work 06:45 to Other 07:30; no other day is touched")
    }

    func testALabelChangeReinstallsOnlyTheDaysOfThatAlarm() throws {
        let before = SmartWakeAlarmBook(alarms: [alarm("Work", days: [2, 3], minutes: 405), alarm("Other", days: [5], minutes: 450)])
        let after = SmartWakeAlarmBook(alarms: [alarm("Job", days: [2, 3], minutes: 405), alarm("Other", days: [5], minutes: 450)])
        let plan = SmartWakeSyncPlan.make(previous: SmartWakeSchedule.compiled(days: specs(before)),
                                          next: try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(after))), osChanged: false)
        XCTAssertEqual(plan, .alarms(install: [2, 3], remove: []))
    }

    func testAWindowOrInsistenceChangeIsMetadataOnly() throws {
        let base = alarm("Work", days: [2, 3, 4], minutes: 405)
        var window = base; window.windowMinutes = 45
        var insistent = base; insistent.insistent = true
        let previous = SmartWakeSchedule.compiled(days: specs(SmartWakeAlarmBook(alarms: [base])))
        for changed in [window, insistent] {
            let plan = SmartWakeSyncPlan.make(previous: previous,
                                              next: try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(SmartWakeAlarmBook(alarms: [changed])))),
                                              osChanged: false)
            XCTAssertEqual(plan, .metadataOnly)
        }
    }

    func testAnOSChangeOrNoSavedScheduleReinstallsEveryActiveDayAndClearsTheRest() throws {
        let s = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(SmartWakeAlarmBook(alarms: [alarm(days: [2, 3], minutes: 405)]))))
        let all: SmartWakeSyncPlan = .alarms(install: [2, 3], remove: [1, 4, 5, 6, 7])
        XCTAssertEqual(SmartWakeSyncPlan.make(previous: s, next: s, osChanged: true), all)
        XCTAssertEqual(SmartWakeSyncPlan.make(previous: nil, next: s, osChanged: false), all)
    }

    // MARK: 4. Who owns the strap alarm

    func testAllowsStrapAlarmRules() {
        let active = SmartWakeAlarmBook(alarms: [alarm(days: [2], minutes: 420)])
        let none = SmartWakeAlarmBook(alarms: [alarm(days: [2], minutes: 420, enabled: false)])
        let empty = SmartWakeAlarmBook()
        // Smart Wake off: always allowed, whatever the list says.
        XCTAssertTrue(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: false, book: active))
        XCTAssertTrue(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: false, book: none))
        XCTAssertTrue(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: false, book: nil))
        // No list yet: allowed.
        XCTAssertTrue(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: true, book: nil))
        // On, with at least one active alarm: allowed.
        XCTAssertTrue(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: true, book: active))
        // On, nothing active (all off, or no alarms at all): not allowed.
        XCTAssertFalse(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: true, book: none))
        XCTAssertFalse(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: true, book: empty))
    }

    func testAllowsStrapAlarmReadingTheStoreNeverWrites() {
        let defaults = makeDefaults()
        let junk = Data("not json".utf8)
        defaults.set(junk, forKey: SmartWakeAlarmBookStorage.key)
        // Smart Wake off: answers before reading, blob untouched.
        XCTAssertTrue(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: false, defaults: defaults))
        // Smart Wake on with a list that cannot be read: allowed, and the blob stays where it is (no `corrupt` key).
        XCTAssertTrue(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: true, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: SmartWakeAlarmBookStorage.key), junk)
        XCTAssertNil(defaults.data(forKey: SmartWakeAlarmBookStorage.corruptKey))

        let fresh = makeDefaults()
        XCTAssertTrue(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: true, defaults: fresh), "no list yet")
        SmartWakeAlarmBookStorage.save(SmartWakeAlarmBook(alarms: [alarm(days: [2], minutes: 420)]), defaults: fresh)
        XCTAssertTrue(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: true, defaults: fresh))
        SmartWakeAlarmBookStorage.save(SmartWakeAlarmBook(alarms: [alarm(days: [2], minutes: 420, enabled: false)]), defaults: fresh)
        XCTAssertFalse(SmartWakeScheduleOwner.allowsStrapAlarm(smartWakeEnabled: true, defaults: fresh))
    }

    // MARK: Migrator

    func testMigrationRunsOnceAndAnExistingListIsNotReadAgain() {
        let defaults = makeDefaults()
        var reads = 0
        let upstream: () -> SmartWakeAlarmBookMigrator.Upstream = {
            reads += 1
            return .init(minutes: 420, weekdays: [2, 3], overrides: [3: 500], windowMinutes: 45, insistent: true)
        }
        let first = SmartWakeAlarmBookMigrator.loadOrMigrate(upstream: upstream, defaults: defaults)
        XCTAssertTrue(first.migrated)
        XCTAssertEqual(first.book.alarms.count, 1)
        let stored = defaults.data(forKey: SmartWakeAlarmBookStorage.key)
        let second = SmartWakeAlarmBookMigrator.loadOrMigrate(upstream: upstream, defaults: defaults)
        XCTAssertFalse(second.migrated)
        XCTAssertEqual(second.book, first.book)
        XCTAssertEqual(reads, 1, "upstream is read only when a migration is needed")
        XCTAssertEqual(defaults.data(forKey: SmartWakeAlarmBookStorage.key), stored)
    }

    func testTheSnapshotOfTheFirstMigrationSurvivesARemigrationAfterAnUnreadableBlob() throws {
        let defaults = makeDefaults()
        let a = SmartWakeAlarmBookMigrator.Upstream(minutes: 420, weekdays: [2, 3], overrides: [3: 500], windowMinutes: 30, insistent: false)
        let snapshotA = SmartWakeAlarmMigration.UpstreamSnapshot(minutes: 420, weekdays: [2, 3], overrides: [3: 500])
        XCTAssertTrue(SmartWakeAlarmBookMigrator.loadOrMigrate(upstream: { a }, defaults: defaults).migrated)
        XCTAssertEqual(SmartWakeAlarmBookStorage.loadSnapshot(defaults: defaults), snapshotA)

        // The list becomes unreadable; by now the upstream settings hold mirrored values, not the original ones.
        let junk = Data("garbage".utf8)
        defaults.set(junk, forKey: SmartWakeAlarmBookStorage.key)
        let b = SmartWakeAlarmBookMigrator.Upstream(minutes: 480, weekdays: [2, 3, 4, 5], overrides: [:], windowMinutes: 45, insistent: true)
        let again = SmartWakeAlarmBookMigrator.loadOrMigrate(upstream: { b }, defaults: defaults)

        XCTAssertTrue(again.migrated)
        XCTAssertEqual(again.book.alarms[0].wakeMinutes, 480, "the list is rebuilt from the current settings")
        XCTAssertEqual(again.book.alarms[0].weekdays, [2, 3, 4, 5])
        XCTAssertEqual(SmartWakeAlarmBookStorage.loadSnapshot(defaults: defaults), snapshotA, "the snapshot stays the first one")
        XCTAssertEqual(defaults.data(forKey: SmartWakeAlarmBookStorage.corruptKey), junk, "the unreadable bytes are kept")
    }

    // MARK: The strap and Smart Wake agree on the next wake among several alarms

    func testTheStrapsNextAlarmIsSmartWakesNextMaximumTimeAcrossAlarmsMidnightAndTheSkip() throws {
        let calendar = rome()
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        // 2026-11-16 is a Monday. Work: Mon-Wed 06:45. Other: Thu-Fri 07:30.
        let book = SmartWakeAlarmBook(alarms: [alarm("Work", days: [2, 3, 4], minutes: 6 * 60 + 45),
                                               alarm("Other", days: [5, 6], minutes: 7 * 60 + 30)])
        let schedule = try XCTUnwrap(SmartWakeSchedule.compiled(days: specs(book)))
        // The upstream settings the mirror leaves behind, starting from a single 07:00 weekday alarm.
        let store = SuiteStore(.init(minutes: 7 * 60, weekdays: [2, 3, 4, 5, 6], overrides: [:]), defaults: makeDefaults())
        SmartWakeUpstreamMirror.apply(effectiveMinutes: minutes(book), to: store)
        let upstream = store.settings

        let froms = [date(16, 6), date(16, 6, 45), date(18, 8), date(19, 7, 29), date(19, 7, 30), date(20, 8), date(21, 12), date(22, 23, 59)]
        for from in froms {
            let strap = AppModel.nextSmartAlarmDate(minutes: upstream.minutes, weekdays: upstream.weekdays,
                                                    overrides: upstream.overrides, from: from, calendar: calendar)
            XCTAssertEqual(strap, schedule.nextMaximumWakeTime(after: from, calendar: calendar), "from \(from)")
        }
        XCTAssertEqual(schedule.nextMaximumWakeTime(after: date(18, 8), calendar: calendar), date(19, 7, 30), "Wed 08:00 -> Thu 07:30")
        XCTAssertEqual(schedule.nextMaximumWakeTime(after: date(20, 8), calendar: calendar), date(23, 6, 45), "Fri 08:00 -> Mon 06:45")

        // Double tap on Thursday's early wake: the firmware search starts after Thursday's maximum time.
        let defaults = makeDefaults()
        SmartWakeFirmwareSkip.record(skipUntil: date(19, 7, 30), defaults: defaults)
        let from = SmartWakeFirmwareSkip.armFrom(now: date(19, 6, 55), smartWakeEnabled: true, defaults: defaults)
        XCTAssertEqual(from, date(19, 7, 30))
        XCTAssertEqual(AppModel.nextSmartAlarmDate(minutes: upstream.minutes, weekdays: upstream.weekdays,
                                                   overrides: upstream.overrides, from: from, calendar: calendar),
                       date(20, 7, 30), "the strap moves on to Friday's alarm")
        XCTAssertEqual(schedule.nextMaximumWakeTime(after: from, calendar: calendar), date(20, 7, 30))
    }
}
