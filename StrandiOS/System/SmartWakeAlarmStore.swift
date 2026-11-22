#if os(iOS)
import Foundation
import SwiftUI

// fork: the Smart Wake alarm list as the app sees it. Pure rules live in `SmartWakeAlarmBook`; this adds persistence,
// the upstream mirror and the debounced sync, so a screen only says "save this alarm".

/// The production `SmartWakeUpstreamStore`: forwards to `BehaviorStore` and `WindDownNudge`.
@MainActor
struct BehaviorUpstreamStore: SmartWakeUpstreamStore {
    let behavior: BehaviorStore

    var settings: SmartWakeUpstreamSettings {
        SmartWakeUpstreamSettings(minutes: behavior.smartAlarmMinutes, weekdays: behavior.smartAlarmWeekdays,
                                  overrides: WindDownNudge.perDayWakeOverrides)
    }
    func setMinutes(_ minutes: Int) { behavior.smartAlarmMinutes = minutes }
    func setWeekdays(_ weekdays: Set<Int>) { behavior.smartAlarmWeekdays = weekdays }
    func setOverride(weekday: Int, minutes: Int?) { WindDownNudge.setWakeOverride(weekday: weekday, minutes: minutes) }

    /// Everything the strap arm reads: the three settings and the strap alarm switch.
    var armFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(settings.minutes)
        hasher.combine(settings.weekdays)
        hasher.combine(settings.overrides)
        hasher.combine(behavior.smartAlarmEnabled)
        return hasher.finalize()
    }
}

@MainActor
final class SmartWakeAlarmStore: ObservableObject {
    static let shared = SmartWakeAlarmStore()

    @Published private(set) var book = SmartWakeAlarmBook()
    /// Bumped on every change of the list, for views that only need to know "it changed".
    @Published private(set) var revision = 0
    private weak var behavior: BehaviorStore?
    private weak var model: AppModel?

    /// The stored list, or the one made from the current single schedule on first use. Writes nothing when it exists.
    static func currentBook(for behavior: BehaviorStore, defaults: UserDefaults = .standard) -> SmartWakeAlarmBook {
        SmartWakeAlarmBookMigrator.loadOrMigrate(upstream: {
            .init(minutes: behavior.smartAlarmMinutes, weekdays: behavior.smartAlarmWeekdays,
                  overrides: WindDownNudge.perDayWakeOverrides, windowMinutes: behavior.smartWakeWindowMinutes,
                  insistent: defaults.bool(forKey: SmartWakeStrapAlarm.insistentKey))
        }, defaults: defaults).book
    }

    /// Connects the store to the settings and the model; loads (and, the first time, migrates) the list.
    func attach(behavior: BehaviorStore, model: AppModel) {
        self.behavior = behavior
        self.model = model
        let loaded = Self.currentBook(for: behavior)
        if loaded != book { book = loaded; revision += 1 }
    }

    /// The next alarm that rings, from the same schedule the detector and AlarmKit are armed from.
    func next(after date: Date = Date(), calendar: Calendar = .current) -> (date: Date, label: String)? {
        guard let behavior, let schedule = SmartWakeLiveWiring.makeSchedule(from: behavior),
              let next = schedule.nextMaximumWakeTime(after: date, calendar: calendar) else { return nil }
        return (next, schedule.label(onWeekday: calendar.component(.weekday, from: next)) ?? "")
    }

    // MARK: Changes

    /// A change from the UI. Nothing is written when it is refused.
    func save(_ alarm: SmartWakeAlarm) -> SmartWakeAlarmBook.Change {
        let change = book.saving(alarm)
        if case let .applied(next) = change { commit(next) }
        return change
    }

    /// Only after the user chose "turn the other one off".
    func saveSwitchingOffConflicts(_ alarm: SmartWakeAlarm) { commit(book.forcing(alarm)) }

    func delete(id: UUID) { commit(book.deleting(id: id)) }

    /// Persists, mirrors the upstream settings and asks for ONE debounced sync.
    private func commit(_ next: SmartWakeAlarmBook) {
        guard next != book else { return }
        SmartWakeAlarmBookStorage.save(next)
        book = next
        mirrorUpstream()
        revision += 1   // fork: after the mirror, so a view reacting to it reads the final upstream settings
        model?.applySmartWakeSchedule()
    }

    /// Brings the upstream alarm settings to what the list resolves to. Writes nothing when they already agree.
    func mirrorUpstream() {
        guard let behavior, let model, behavior.smartWakeEnabled else { return }
        let minutes = book.effectiveDays().mapValues(\.minutes)
        let hold = SmartWakeArmHold.shared
        let changes = SmartWakeUpstreamMirror.apply(
            effectiveMinutes: minutes, to: BehaviorUpstreamStore(behavior: behavior),
            hold: hold, arm: { [weak model] in model?.applySmartAlarm() })
        if changes.isEmpty {
            // Nothing written, so no echo will re-arm the strap: do it here (it disarms when no alarm is active).
            model.applySmartAlarm()
        } else {
            hold.finish()
        }
    }
}
#endif
