import Foundation

// fork: how the Smart Wake alarm list and the upstream WHOOP alarm settings stay one fact.
//
// While Smart Wake is on, the list is the source of the schedule. The upstream settings (`smartAlarmMinutes`,
// `smartAlarmWeekdays` and the per-day wake overrides) are kept equal to what the list resolves to, so
// `applySmartAlarm()`, the strap's firmware alarm, the backup notification, the "next buzz" line and the evening
// reminder all read the next occurrence among ALL active alarms without being changed. Pure Foundation.

/// The three upstream values that describe the alarm schedule.
struct SmartWakeUpstreamSettings: Equatable {
    var minutes: Int
    /// Empty means every day, as upstream reads it.
    var weekdays: Set<Int>
    var overrides: [Int: Int]
}

/// Reads and writes the upstream settings. The production implementation forwards to `BehaviorStore` and
/// `WindDownNudge`; tests use a store that records every write.
protocol SmartWakeUpstreamStore {
    var settings: SmartWakeUpstreamSettings { get }
    func setMinutes(_ minutes: Int)
    func setWeekdays(_ weekdays: Set<Int>)
    /// `minutes == nil` clears that weekday's override.
    func setOverride(weekday: Int, minutes: Int?)
    /// Identifies everything the strap arm reads, so the arm hold can tell an echo of its own writes from a real change.
    /// The default covers the three settings; the production store adds `smartAlarmEnabled`. Compared within one
    /// process only (it is a `Hasher` value).
    var armFingerprint: Int { get }
}

extension SmartWakeUpstreamStore {
    var armFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(settings.minutes)
        hasher.combine(settings.weekdays)
        hasher.combine(settings.overrides)
        return hasher.finalize()
    }
}

enum SmartWakeUpstreamMirror {
    struct Changes: Equatable {
        var minutes: Int?
        var weekdays: Set<Int>?
        var overrideSets: [Int: Int] = [:]
        var overrideClears: Set<Int> = []

        var isEmpty: Bool { minutes == nil && weekdays == nil && overrideSets.isEmpty && overrideClears.isEmpty }
    }

    /// The upstream settings that resolve to `effectiveMinutes` (weekday -> wake time of the active alarm there).
    ///
    /// - Nothing active: `current` unchanged (the strap alarm is disarmed by the owner rule, not by emptying settings).
    /// - Weekdays: the active days; all seven stay as they are when `current` already says "every day" in either
    ///   spelling, otherwise the empty set (upstream's canonical form).
    /// - Already consistent (the current base and overrides resolve every active day to its time): times are left alone.
    /// - Base time: `current.minutes` while some active day still uses it, else the most frequent active time (ties go
    ///   to the earlier one). Keeping it means a configuration the list was made from needs no write at all.
    /// - Overrides: an active day gets an override only when its time differs from the base. A redundant override that
    ///   already equals the day's time is left alone. Overrides of days that are not active are kept: the evening
    ///   reminder still reads them.
    static func target(current: SmartWakeUpstreamSettings, effectiveMinutes: [Int: Int]) -> SmartWakeUpstreamSettings {
        let valid = effectiveMinutes.filter { (1...7).contains($0.key) && (0..<24 * 60).contains($0.value) }
        guard !valid.isEmpty else { return current }

        let active = Set(valid.keys)
        let weekdays: Set<Int>
        if active.count == 7 {
            weekdays = (current.weekdays.isEmpty || current.weekdays == Set(1...7)) ? current.weekdays : []
        } else {
            weekdays = active
        }

        // Already consistent: the current base and overrides resolve every active day to the time the list gives it. Then
        // nothing about times is written, whatever shape the current values have (this is what makes mirroring a list that
        // was just migrated from them a no-op, including when every active day carries its own override).
        if valid.allSatisfy({ (current.overrides[$0.key] ?? current.minutes) == $0.value }) {
            return SmartWakeUpstreamSettings(minutes: current.minutes, weekdays: weekdays, overrides: current.overrides)
        }

        let times = Array(valid.values)
        let base: Int
        if times.contains(current.minutes) {
            base = current.minutes
        } else {
            let counts = Dictionary(times.map { ($0, 1) }, uniquingKeysWith: +)
            base = counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }!.key
        }

        var overrides = current.overrides
        for (day, minutes) in valid {
            if overrides[day] == minutes { continue }
            if minutes == base { overrides.removeValue(forKey: day) } else { overrides[day] = minutes }
        }
        return SmartWakeUpstreamSettings(minutes: base, weekdays: weekdays, overrides: overrides)
    }

    /// The writes needed to go from `current` to `target`. Empty when they are equal.
    static func changes(from current: SmartWakeUpstreamSettings, to target: SmartWakeUpstreamSettings) -> Changes {
        var changes = Changes()
        if target.minutes != current.minutes { changes.minutes = target.minutes }
        if target.weekdays != current.weekdays { changes.weekdays = target.weekdays }
        for day in 1...7 {
            switch (current.overrides[day], target.overrides[day]) {
            case let (old, new?) where old != new: changes.overrideSets[day] = new
            case (_?, nil): changes.overrideClears.insert(day)
            default: break
            }
        }
        return changes
    }

    /// Brings the store to the settings that resolve to `effectiveMinutes`, writing only what differs.
    ///
    /// When it writes anything it first opens `hold` (with the `arm` to run), so the arm requests that the writes provoke
    /// elsewhere (the Alarms screen re-arms from an `onChange` of each of these values, one render pass after the write)
    /// are swallowed instead of arming the strap at a half-written configuration. The caller then calls `hold.finish()`,
    /// which arms once on the final settings. With no change nothing is written and no hold is opened.
    @discardableResult
    static func apply(effectiveMinutes: [Int: Int], to store: some SmartWakeUpstreamStore,
                      hold: SmartWakeArmHold? = nil, arm: @escaping () -> Void = {}) -> Changes {
        let current = store.settings
        let changes = changes(from: current, to: target(current: current, effectiveMinutes: effectiveMinutes))
        if !changes.isEmpty { hold?.begin(arm: arm, fingerprint: { store.armFingerprint }) }
        if let minutes = changes.minutes { store.setMinutes(minutes) }
        if let weekdays = changes.weekdays { store.setWeekdays(weekdays) }
        for (day, minutes) in changes.overrideSets.sorted(by: { $0.key < $1.key }) { store.setOverride(weekday: day, minutes: minutes) }
        for day in changes.overrideClears.sorted() { store.setOverride(weekday: day, minutes: nil) }
        return changes
    }
}

/// Which alarm owns the strap's firmware alarm.
enum SmartWakeScheduleOwner {
    /// Whether `applySmartAlarm()` may arm the strap. False only in one case: Smart Wake is on, the list exists and has
    /// no active alarm, so there is no wake time to arm for. Everything else (Smart Wake off, no list yet, at least one
    /// active alarm) leaves the existing behavior exactly as it was.
    static func allowsStrapAlarm(smartWakeEnabled: Bool, book: SmartWakeAlarmBook?) -> Bool {
        guard smartWakeEnabled, let book else { return true }
        return book.hasActiveAlarm
    }

    /// The same rule reading the stored list. With Smart Wake off it answers before reading anything, and it never
    /// writes (`peek` leaves an unreadable blob where it is). Smart Wake cannot be switched on outside iOS, so there the
    /// first guard always answers true.
    static func allowsStrapAlarm(smartWakeEnabled: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard smartWakeEnabled else { return true }
        guard case let .book(book) = SmartWakeAlarmBookStorage.peek(defaults: defaults) else { return true }
        return allowsStrapAlarm(smartWakeEnabled: true, book: book)
    }
}

/// Keeps the strap from being armed at a half-written configuration while the mirror updates the upstream settings, and
/// from being armed again by the echoes of those writes.
///
/// The three settings are written one at a time and the Alarms screen calls `applySmartAlarm()` from an `onChange` of
/// each of them, one render pass AFTER the write, so a single list change could otherwise arm the strap two or three
/// times, the first with only some of the new values. The flow:
///
/// 1. `begin(arm:fingerprint:)`, before the writes. From now an arm is OWED and the window (`until`) is open.
/// 2. `applySmartAlarm()` asks `swallows()` first. During the writes the answer is yes: the owed arm will read the
///    complete configuration.
/// 3. `finish()` arms now, once, and does NOT close the window. The arm has read the final settings, so requests that
///    arrive until `until` (the `onChange` echoes) are ignored, but only while the settings still match what that arm
///    read. A request that finds them different (the user changed something inside the window) is not swallowed, so a
///    real change is never lost.
/// 4. If `finish()` never comes, a timer fires at `until` and arms once. If the timer is late (the app was suspended),
///    the first `applySmartAlarm()` after `until` goes through and settles the owed arm itself, and the late timer then
///    finds nothing owed.
///
/// So every `begin` ends in exactly one arm, on the complete configuration, whatever number of requests were swallowed.
/// When nothing was written no hold exists and `swallows()` is false, so with Smart Wake or the list off
/// `applySmartAlarm()` behaves exactly as before. Main thread only (the arm paths all run there).
final class SmartWakeArmHold {
    static let shared = SmartWakeArmHold()
    static let defaultWindow: TimeInterval = 1.5

    /// Runs `work` after `delay` seconds. Injected so tests drive the timer by hand.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private let window: TimeInterval
    private let now: () -> Date
    private let schedule: Scheduler
    private var until: Date?
    private var owed = false
    private var arming = false
    private var arm: (() -> Void)?
    private var fingerprint: (() -> Int)?
    private var armedFingerprint: Int?
    private var generation = 0

    init(window: TimeInterval = SmartWakeArmHold.defaultWindow, now: @escaping () -> Date = Date.init,
         schedule: @escaping Scheduler = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.window = window
        self.now = now
        self.schedule = schedule
    }

    /// True while the window is open (an arm owed, or done and its echoes still being ignored).
    var isHolding: Bool {
        guard let until else { return false }
        return now() < until
    }

    /// Opens, or extends, the hold; an arm is owed from here. Called by the mirror before it writes.
    func begin(arm: @escaping () -> Void, fingerprint: @escaping () -> Int) {
        self.arm = arm
        self.fingerprint = fingerprint
        owed = true
        armedFingerprint = nil
        until = now().addingTimeInterval(window)
        generation += 1
        let mine = generation
        schedule(window) { [weak self] in self?.expire(generation: mine) }
    }

    /// Asked at the top of `applySmartAlarm()`: true means skip this call.
    func swallows() -> Bool {
        guard !arming, let until else { return false }
        guard now() < until else {
            // The window is over and the timer has not run (or never will, if the app was suspended). This very call
            // is the arm that was owed, so settle it here instead of arming twice.
            close()
            return false
        }
        if owed { return true }   // the commit has not armed yet; it will, with the complete configuration
        if let armedFingerprint, let fingerprint, fingerprint() != armedFingerprint { return false }   // a real change
        return true               // an echo of the writes the arm already read
    }

    /// Arms now, once, if an arm is owed. The window stays open for the echoes. Returns whether it armed.
    @discardableResult
    func finish() -> Bool {
        guard owed else { return false }
        armNow()
        return true
    }

    private func expire(generation expired: Int) {
        guard expired == generation, until != nil else { return }   // a later begin owns the window now
        if owed { armNow() }
        close()
    }

    private func armNow() {
        owed = false
        armedFingerprint = fingerprint?()
        let action = arm
        arming = true            // the arm goes through `applySmartAlarm()`, which asks `swallows()` first
        action?()
        arming = false
    }

    private func close() {
        until = nil
        owed = false
        arm = nil
        fingerprint = nil
        armedFingerprint = nil
        generation += 1          // a timer scheduled earlier now finds a different generation and does nothing
    }
}
