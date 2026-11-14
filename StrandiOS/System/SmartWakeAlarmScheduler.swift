#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import AppIntents
import Foundation
import SwiftUI

@available(iOS 26.0, *)
private struct SmartWakeAlarmMetadata: AlarmMetadata {}

/// The system-owned maximum-time alarm and the early-wake handoff.
///
/// A separate recurring AlarmKit alarm is kept for each weekday. When Smart Wake detects
/// a valid early trigger, it schedules a one-shot alarm first, then replaces only that
/// weekday's fallback. Dismissing the early alarm re-arms that weekday through its stop intent.
@available(iOS 26.0, *)
@MainActor
final class SmartWakeAlarmScheduler {
    static let shared = SmartWakeAlarmScheduler()

    private let manager = AlarmManager.shared
    private let defaults = UserDefaults.standard

    private let enabledKey = "smartWake.alarmKit.enabled"
    private let scheduleKey = "smartWake.alarmKit.schedule"
    private let earlyAlarmIDKey = "smartWake.alarmKit.earlyAlarmID"
    private let earlyAlarmWeekdayKey = "smartWake.alarmKit.earlyAlarmWeekday"
    private let earlyAlarmScheduledKey = "smartWake.alarmKit.earlyAlarmScheduled"
    private let lastErrorKey = "smartWake.alarmKit.lastError"
    private let fallbackSlotsKey = "smartWake.alarmKit.fallbackSlots"
    private let lastOSVersionKey = "smartWake.alarmKit.lastOSVersion"
    private static var currentOSVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
    private var updatesTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var handoffInProgress = false
    /// Tail of the serial operation queue. enable / sync / disable / early-wake / reconcile all run
    /// one after another, so the foreground re-sync triggered by the AlarmKit permission prompt can
    /// never interleave with the `enable` that is still waiting on that prompt.
    private var queueTail: Task<Void, Never>?

    static let revokedAuthorizationMessage = "Alarm permission was revoked in Settings."

    enum SyncOutcome: Equatable {
        /// Nothing needed doing (disabled, already in sync, or authorization not yet decided).
        case unchanged
        /// The schedule was applied.
        case synced
        /// The user revoked the Alarms permission; Smart Wake has been switched off.
        case denied
        /// AlarmKit refused the schedule update. Existing alarms were kept and enabled stays on.
        case failed
    }

    enum EnableOutcome: Equatable {
        /// Authorized and every fallback scheduled.
        case enabled
        /// Authorized, but AlarmKit refused part of the schedule. Existing alarms were kept and the
        /// next sync retries.
        case enabledWithError
        /// Not authorized (or the request itself failed): nothing is armed and Smart Wake is off.
        case notAuthorized
    }

    /// Two alarm IDs per weekday. A reschedule installs the new alarm in the idle slot and only
    /// then removes the live one, so there is no moment with zero fallbacks. Slot 0 keeps the IDs
    /// shipped before slots existed, so alarms already on a device are adopted as they are.
    private static let fallbackIDsBySlot: [[Int: UUID]] = [
        [
            1: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!,
            2: UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!,
            3: UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!,
            4: UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!,
            5: UUID(uuidString: "A1000000-0000-4000-8000-000000000005")!,
            6: UUID(uuidString: "A1000000-0000-4000-8000-000000000006")!,
            7: UUID(uuidString: "A1000000-0000-4000-8000-000000000007")!
        ],
        [
            1: UUID(uuidString: "B1000000-0000-4000-8000-000000000001")!,
            2: UUID(uuidString: "B1000000-0000-4000-8000-000000000002")!,
            3: UUID(uuidString: "B1000000-0000-4000-8000-000000000003")!,
            4: UUID(uuidString: "B1000000-0000-4000-8000-000000000004")!,
            5: UUID(uuidString: "B1000000-0000-4000-8000-000000000005")!,
            6: UUID(uuidString: "B1000000-0000-4000-8000-000000000006")!,
            7: UUID(uuidString: "B1000000-0000-4000-8000-000000000007")!
        ]
    ]

    private static func fallbackID(weekday: Int, slot: Int) -> UUID? {
        guard fallbackIDsBySlot.indices.contains(slot) else { return nil }
        return fallbackIDsBySlot[slot][weekday]
    }

    private var allFallbackIDs: [UUID] {
        Self.fallbackIDsBySlot.flatMap { $0.values }
    }

    /// Weekday → live slot (0 or 1). A missing entry means slot 0.
    private func loadSlots() -> [Int: Int] {
        guard let data = defaults.data(forKey: fallbackSlotsKey),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        var slots: [Int: Int] = [:]
        for (key, value) in raw {
            if let weekday = Int(key), (1...7).contains(weekday), (0...1).contains(value) {
                slots[weekday] = value
            }
        }
        return slots
    }

    private func activeSlot(for weekday: Int) -> Int {
        loadSlots()[weekday] ?? 0
    }

    private func setActiveSlot(_ slot: Int, for weekday: Int) {
        var slots = loadSlots()
        slots[weekday] = slot
        let raw = Dictionary(uniqueKeysWithValues: slots.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: fallbackSlotsKey)
        }
    }

    private func activeFallbackID(for weekday: Int) -> UUID? {
        Self.fallbackID(weekday: weekday, slot: activeSlot(for: weekday))
    }

    /// Both slots of a weekday: the live one and the idle one.
    private func fallbackIDs(for weekday: Int) -> [UUID] {
        (0...1).compactMap { Self.fallbackID(weekday: weekday, slot: $0) }
    }

    private func presentAlarmIDs() -> Set<UUID> {
        Set((try? manager.alarms)?.map(\.id) ?? [])
    }

    private init() {}

    fileprivate func serialized<T>(_ operation: @escaping () async -> T) async -> T {
        let previous = queueTail
        let task = Task { () -> T in
            await previous?.value
            return await operation()
        }
        queueTail = Task { _ = await task.value }
        return await task.value
    }

    var isAuthorized: Bool {
        manager.authorizationState == .authorized
    }

    /// True only when the user has explicitly refused (or later revoked) the Alarms permission.
    var isDenied: Bool {
        manager.authorizationState == .denied
    }

    var isConfigured: Bool {
        defaults.bool(forKey: enabledKey) && isAuthorized
    }

    /// The last concrete AlarmKit failure, retained locally for the Smart Wake settings UI.
    var lastErrorDescription: String? {
        defaults.string(forKey: lastErrorKey)
    }

    /// Observe the system's alarm list so a dismissed one-shot early alarm restores its
    /// recurring fallback even if the stop intent could not run while the app was suspended.
    func startObserving() {
        if let currentAlarms = try? manager.alarms {
            Task { [weak self] in
                await self?.reconcile(with: currentAlarms)
            }
        }

        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await alarms in AlarmManager.shared.alarmUpdates {
                    await self?.reconcile(with: alarms)
                }
            }
        }

        if authorizationTask == nil {
            authorizationTask = Task { [weak self] in
                for await state in AlarmManager.shared.authorizationUpdates {
                    if state == .denied {
                        await self?.handleRevokedAuthorization()
                    }
                }
            }
        }
    }

    private func reconcile(with alarms: [Alarm]) async {
        await serialized { await self.reconcileEarlyAlarm(with: alarms) }
    }

    private func handleRevokedAuthorization() async {
        await serialized { await self.disableForRevokedAuthorization() }
    }

    private func disableForRevokedAuthorization() async {
        defaults.set(Self.revokedAuthorizationMessage, forKey: lastErrorKey)
        defaults.set(false, forKey: enabledKey)
        await cancelAllManagedAlarms()
    }

    private func reconcileEarlyAlarm(with alarms: [Alarm]) async {
        guard !handoffInProgress, defaults.bool(forKey: enabledKey) else { return }

        if let raw = defaults.string(forKey: earlyAlarmIDKey),
           let earlyID = UUID(uuidString: raw),
           let weekday = defaults.object(forKey: earlyAlarmWeekdayKey) as? Int,
           (1...7).contains(weekday) {
            let earlyIsPresent = alarms.contains(where: { $0.id == earlyID })
            let weekdayFallbackIDs = fallbackIDs(for: weekday)
            let fallbackIsPresent = alarms.contains(where: { weekdayFallbackIDs.contains($0.id) })
            if earlyIsPresent {
                // Recover a crash between scheduling the early alert and cancelling its fallback.
                defaults.set(true, forKey: earlyAlarmScheduledKey)
                for id in weekdayFallbackIDs where alarms.contains(where: { $0.id == id }) {
                    try? manager.cancel(id: id)
                }
            } else if defaults.bool(forKey: earlyAlarmScheduledKey) {
                // The early alert was scheduled and has now been dismissed. Skip today's maximum
                // time, then resume the normal weekly recurrence from the following week.
                await Self.performRearmFallback(for: weekday, skipCurrentOccurrence: true)
            } else if fallbackIsPresent {
                // The process died before the early alert was actually scheduled; preserve today's fallback.
                defaults.removeObject(forKey: earlyAlarmIDKey)
                defaults.removeObject(forKey: earlyAlarmWeekdayKey)
                defaults.removeObject(forKey: earlyAlarmScheduledKey)
            } else {
                await Self.performRearmFallback(for: weekday, skipCurrentOccurrence: false)
            }
            return
        }

        // Recover any weekday alarm removed by the system or a previous interrupted scheduling pass.
        guard let schedule = loadSchedule() else { return }
        let selectedDays = schedule.weekdays.isEmpty ? Set(1...7) : schedule.weekdays
        let present = Set(alarms.map(\.id))
        for weekday in 1...7 {
            let slotIDs = fallbackIDs(for: weekday)
            let presentSlots = (0...1).filter { slot in
                Self.fallbackID(weekday: weekday, slot: slot).map(present.contains) ?? false
            }
            guard selectedDays.contains(weekday) else {
                // A day that is no longer selected must not keep ringing; this retries a removal that failed.
                for id in slotIDs where present.contains(id) { try? manager.cancel(id: id) }
                continue
            }
            switch presentSlots.count {
            case 0:
                await rearm(weekday: weekday, skipCurrentOccurrence: false)
            case 1:
                // Adopt whichever slot is live, e.g. after a pass that died between scheduling the
                // new alarm and recording it.
                setActiveSlot(presentSlots[0], for: weekday)
            default:
                // Both slots hold an alarm: a previous swap could not remove the old one. The live
                // slot is the one recorded last; remove the other (a double alarm is better than none,
                // but it must not last).
                let live = activeSlot(for: weekday)
                if let idleID = Self.fallbackID(weekday: weekday, slot: 1 - live) {
                    do {
                        try manager.cancel(id: idleID)
                    } catch {
                        defaults.set("Could not remove a superseded Smart Wake alarm (will retry): \(error.localizedDescription)", forKey: lastErrorKey)
                    }
                }
            }
        }
    }

    /// Called only after the user explicitly enables Smart Wake.
    func enable(schedule: SmartWakeSchedule) async -> EnableOutcome {
        guard #available(iOS 26.0, *) else { return .notAuthorized }
        return await serialized { await self.performEnable(schedule: schedule) }
    }

    private func performEnable(schedule: SmartWakeSchedule) async -> EnableOutcome {
        let authorization: AlarmManager.AuthorizationState
        if manager.authorizationState == .notDetermined {
            do {
                authorization = try await manager.requestAuthorization()
            } catch {
                defaults.set("AlarmKit authorization request failed: \(error.localizedDescription)", forKey: lastErrorKey)
                defaults.set(false, forKey: enabledKey)
                return .notAuthorized
            }
        } else {
            authorization = manager.authorizationState
        }
        guard authorization == .authorized else {
            defaults.set("AlarmKit authorization state: \(String(describing: authorization)). NOOP is not authorized to schedule system alarms.", forKey: lastErrorKey)
            defaults.set(false, forKey: enabledKey)
            await cancelAllManagedAlarms()
            return .notAuthorized
        }

        defaults.set(true, forKey: enabledKey)
        do {
            try await replaceFallbacks(with: schedule)
            defaults.removeObject(forKey: lastErrorKey)
            return .enabled
        } catch {
            // Authorized but AlarmKit refused (some of) the schedule. Keep whatever is already armed
            // and stay enabled: the next foreground sync retries, and the error stays visible.
            defaults.set("AlarmKit scheduling failed: \(error.localizedDescription)", forKey: lastErrorKey)
            return .enabledWithError
        }
    }

    func disable() async {
        await serialized { await self.performDisable() }
    }

    private func performDisable() async {
        defaults.set(false, forKey: enabledKey)
        await cancelAllManagedAlarms()
    }

    /// Reconcile an already-authorized schedule after a settings change or foreground launch.
    /// This method never opens the system authorization prompt. `isEnabled` is read when the
    /// operation actually runs (after any in-flight `enable`), not when it was requested.
    @discardableResult
    func sync(isEnabled: @escaping () -> Bool, schedule: SmartWakeSchedule) async -> SyncOutcome {
        guard #available(iOS 26.0, *) else { return .unchanged }
        return await serialized { await self.performSync(enabled: isEnabled(), schedule: schedule) }
    }

    private func performSync(enabled: Bool, schedule: SmartWakeSchedule) async -> SyncOutcome {
        guard enabled else {
            await performDisable()
            return .unchanged
        }
        switch manager.authorizationState {
        case .authorized:
            break
        case .denied:
            // Only an explicit refusal switches Smart Wake off.
            await disableForRevokedAuthorization()
            return .denied
        default:
            // Not decided yet: leave the toggle and any existing alarms alone.
            return .unchanged
        }
        // Every foreground (and launch) reconciles against the system's actual alarm list. This is
        // deliberately independent of `alarmUpdates`: on recent iOS versions that stream may only be
        // delivered once the app runs again, so a dismissed early alarm whose stop intent did not run
        // overnight is repaired here, at the first foreground, and never depends on a live observer.
        if defaults.bool(forKey: enabledKey), let current = try? manager.alarms {
            await reconcileEarlyAlarm(with: current)
        }

        // An iOS update can silently drop or silence AlarmKit alarms, so a changed OS build forces
        // one reinstall of the fallbacks. It goes through the idle-slot swap, never through zero.
        let osChanged = defaults.string(forKey: lastOSVersionKey) != Self.currentOSVersion
        if defaults.bool(forKey: enabledKey), loadSchedule() == schedule, !osChanged { return .unchanged }

        defaults.set(true, forKey: enabledKey)
        do {
            try await replaceFallbacks(with: schedule)
            return .synced
        } catch {
            // Keep the alarms that are already armed and stay enabled; the next sync retries
            // (the saved schedule was not advanced, so it still differs). The WHOOP firmware alarm
            // is untouched.
            defaults.set("AlarmKit schedule update failed: \(error.localizedDescription)", forKey: lastErrorKey)
            return .failed
        }
    }

    /// Called only for a sustained-HR decision, never for the maximum-time detector result.
    func triggerEarlyWake(at receivedAt: Date, schedule: SmartWakeSchedule) async {
        guard #available(iOS 26.0, *) else { return }
        await serialized { await self.performEarlyWake(at: receivedAt, schedule: schedule) }
    }

    private func performEarlyWake(at receivedAt: Date, schedule: SmartWakeSchedule) async {
        guard defaults.bool(forKey: enabledKey),
              manager.authorizationState == .authorized,
              loadSchedule() == schedule
        else { return }

        let calendar = Calendar.current
        guard let maximumWakeTime = schedule.nextMaximumWakeTime(after: receivedAt, calendar: calendar) else { return }
        let weekday = calendar.component(.weekday, from: maximumWakeTime)
        guard schedule.isEnabled(onWeekday: weekday),
              receivedAt < maximumWakeTime,
              receivedAt >= maximumWakeTime.addingTimeInterval(-schedule.windowDuration),
              let fallbackID = activeFallbackID(for: weekday)
        else { return }

        handoffInProgress = true
        defer { handoffInProgress = false }
        let earlyID = UUID()
        let earlySchedule = Alarm.Schedule.fixed(Date().addingTimeInterval(8))
        let configuration = Self.alarmConfiguration(
            schedule: earlySchedule,
            stopIntent: SmartWakeRearmIntent(weekday: weekday, skipCurrentOccurrence: true)
        )

        // Persist the handoff before the first async system call. If iOS kills the process between
        // scheduling and cancellation, the alarmUpdates observer can finish the reconciliation.
        defaults.set(earlyID.uuidString, forKey: earlyAlarmIDKey)
        defaults.set(weekday, forKey: earlyAlarmWeekdayKey)
        defaults.set(false, forKey: earlyAlarmScheduledKey)
        do {
            // Schedule first. If this fails, the maximum-time fallback is still armed.
            try await manager.schedule(id: earlyID, configuration: configuration)
            defaults.set(true, forKey: earlyAlarmScheduledKey)
            do {
                try manager.cancel(id: fallbackID)
                // The idle slot normally holds nothing; clear a leftover so it cannot ring as well.
                for id in fallbackIDs(for: weekday) where id != fallbackID { try? manager.cancel(id: id) }
            } catch {
                // Never leave two alarms armed for the same morning.
                try? manager.cancel(id: earlyID)
                defaults.removeObject(forKey: earlyAlarmIDKey)
                defaults.removeObject(forKey: earlyAlarmWeekdayKey)
                defaults.removeObject(forKey: earlyAlarmScheduledKey)
            }
        } catch {
            defaults.removeObject(forKey: earlyAlarmIDKey)
            defaults.removeObject(forKey: earlyAlarmWeekdayKey)
            defaults.removeObject(forKey: earlyAlarmScheduledKey)
            // Keep the maximum-time fallback; early wake is best-effort.
        }
    }

    /// Entry point for the stop intent. Runs on the same serial queue as enable / sync / reconcile
    /// so a dismissal can never overlap one of them.
    fileprivate static func rearmFallback(for weekday: Int, skipCurrentOccurrence: Bool) async {
        guard #available(iOS 26.0, *) else { return }
        await shared.serialized {
            await SmartWakeAlarmScheduler.performRearmFallback(
                for: weekday,
                skipCurrentOccurrence: skipCurrentOccurrence
            )
        }
    }

    /// The unserialized body, for callers that already run inside the queue (reconcile).
    fileprivate static func performRearmFallback(for weekday: Int, skipCurrentOccurrence: Bool) async {
        guard #available(iOS 26.0, *) else { return }
        await shared.rearm(weekday: weekday, skipCurrentOccurrence: skipCurrentOccurrence)
    }

    private func rearm(weekday: Int, skipCurrentOccurrence: Bool) async {
        guard (1...7).contains(weekday),
              defaults.bool(forKey: enabledKey),
              let schedule = loadSchedule(),
              schedule.isEnabled(onWeekday: weekday),
              let localeWeekday = Self.localeWeekday(for: weekday)
        else { return }

        let minutes = schedule.wakeMinutes(onWeekday: weekday)
        do {
            let configuration: AlarmManager.AlarmConfiguration<SmartWakeAlarmMetadata>
            if skipCurrentOccurrence {
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                let todayWeekday = calendar.component(.weekday, from: today)
                let daysUntilWeekday = (weekday - todayWeekday + 7) % 7
                let nextOccurrenceOffset = daysUntilWeekday == 0 ? 7 : daysUntilWeekday
                guard let nextWeekday = calendar.date(byAdding: .day, value: nextOccurrenceOffset, to: today),
                      let nextOccurrence = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: nextWeekday)
                else { return }
                configuration = Self.alarmConfiguration(
                    schedule: .fixed(nextOccurrence),
                    stopIntent: SmartWakeRearmIntent(weekday: weekday, skipCurrentOccurrence: false)
                )
            } else {
                let relative = Alarm.Schedule.Relative(
                    time: Alarm.Schedule.Relative.Time(hour: minutes / 60, minute: minutes % 60),
                    repeats: .weekly([localeWeekday])
                )
                configuration = Self.alarmConfiguration(schedule: .relative(relative), stopIntent: nil)
            }
            try await installFallback(weekday: weekday, configuration: configuration)
            defaults.removeObject(forKey: earlyAlarmIDKey)
            defaults.removeObject(forKey: earlyAlarmWeekdayKey)
            defaults.removeObject(forKey: earlyAlarmScheduledKey)
        } catch {
            // The next foreground reconciliation can restore the fallback.
        }
    }

    /// Installs `configuration` as this weekday's fallback without ever passing through zero alarms:
    /// schedule it in the idle slot, record that slot as live, and only then remove the old alarm.
    /// If the removal fails the new alarm stays (a double alarm beats none); the next reconciliation
    /// finds both slots occupied and retries the removal.
    private func installFallback(
        weekday: Int,
        configuration: AlarmManager.AlarmConfiguration<SmartWakeAlarmMetadata>
    ) async throws {
        let live = activeSlot(for: weekday)
        guard let newID = Self.fallbackID(weekday: weekday, slot: 1 - live),
              let oldID = Self.fallbackID(weekday: weekday, slot: live)
        else { return }

        // The idle slot is not the live fallback; clear a leftover so schedule(id:) cannot collide with it.
        try? manager.cancel(id: newID)
        try await manager.schedule(id: newID, configuration: configuration)
        setActiveSlot(1 - live, for: weekday)

        guard presentAlarmIDs().contains(oldID) else { return }
        do {
            try manager.cancel(id: oldID)
        } catch {
            defaults.set("Could not remove a superseded Smart Wake alarm (will retry): \(error.localizedDescription)", forKey: lastErrorKey)
        }
    }

    /// Schedules every selected weekday through `installFallback` and removes deselected days.
    /// A failure on one day keeps that day's existing alarm and does not stop the others; the first
    /// failure is thrown after the pass. The saved schedule advances only when every day succeeded,
    /// so a later sync retries.
    private func replaceFallbacks(with schedule: SmartWakeSchedule) async throws {
        let selectedDays = schedule.weekdays.isEmpty ? Set(1...7) : schedule.weekdays
        var firstFailure: SmartWakeSchedulingError?
        for weekday in selectedDays.sorted() {
            guard let localeWeekday = Self.localeWeekday(for: weekday) else { continue }

            let minutes = schedule.wakeMinutes(onWeekday: weekday)
            let relative = Alarm.Schedule.Relative(
                time: Alarm.Schedule.Relative.Time(hour: minutes / 60, minute: minutes % 60),
                repeats: .weekly([localeWeekday])
            )
            let configuration = Self.alarmConfiguration(
                schedule: .relative(relative),
                stopIntent: nil
            )
            do {
                try await installFallback(weekday: weekday, configuration: configuration)
            } catch {
                if firstFailure == nil {
                    firstFailure = SmartWakeSchedulingError.weekday(
                        weekday: weekday,
                        time: String(format: "%02d:%02d", minutes / 60, minutes % 60),
                        reason: error.localizedDescription
                    )
                }
            }
        }

        for weekday in 1...7 where !selectedDays.contains(weekday) {
            for id in fallbackIDs(for: weekday) { try? manager.cancel(id: id) }
        }

        if let firstFailure { throw firstFailure }

        if let data = try? JSONEncoder().encode(schedule) {
            defaults.set(data, forKey: scheduleKey)
        }
        // Recorded only after a fully successful pass, so a failed one is retried at the next foreground.
        defaults.set(Self.currentOSVersion, forKey: lastOSVersionKey)
    }

    /// Removes every alarm this component owns. Only for an explicit disable or a revoked permission.
    private func cancelAllManagedAlarms() async {
        for id in allFallbackIDs {
            try? manager.cancel(id: id)
        }
        defaults.removeObject(forKey: fallbackSlotsKey)
        if let raw = defaults.string(forKey: earlyAlarmIDKey),
           let id = UUID(uuidString: raw) {
            try? manager.cancel(id: id)
        }
        defaults.removeObject(forKey: earlyAlarmIDKey)
        defaults.removeObject(forKey: earlyAlarmWeekdayKey)
        defaults.removeObject(forKey: earlyAlarmScheduledKey)
    }

    private func loadSchedule() -> SmartWakeSchedule? {
        guard let data = defaults.data(forKey: scheduleKey) else { return nil }
        return try? JSONDecoder().decode(SmartWakeSchedule.self, from: data)
    }

    private static func alarmConfiguration(
        schedule: Alarm.Schedule,
        stopIntent: (any LiveActivityIntent)?
    ) -> AlarmManager.AlarmConfiguration<SmartWakeAlarmMetadata> {
        let stopButton = AlarmButton(
            text: "Stop",
            textColor: .white,
            systemImageName: "stop.circle.fill"
        )
        let alert = AlarmPresentation.Alert(title: "Smart Wake", stopButton: stopButton)
        let attributes = AlarmAttributes<SmartWakeAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: SmartWakeAlarmMetadata(),
            tintColor: .orange
        )
        return AlarmManager.AlarmConfiguration.alarm(
            schedule: schedule,
            attributes: attributes,
            stopIntent: stopIntent,
            secondaryIntent: nil,
            sound: .default
        )
    }

    private static func localeWeekday(for weekday: Int) -> Locale.Weekday? {
        switch weekday {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        case 7: .saturday
        default: nil
        }
    }
}

private enum SmartWakeSchedulingError: LocalizedError {
    case weekday(weekday: Int, time: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .weekday(weekday, time, reason):
            return "Could not schedule the maximum-time fallback for weekday \(weekday) at \(time): \(reason)"
        }
    }
}

/// Runs when the user dismisses an early Smart Wake alert, restoring the recurring
/// maximum-time fallback for that weekday.
@available(iOS 26.0, *)
public struct SmartWakeRearmIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Restore Smart Wake fallback"
    public static var isDiscoverable: Bool = false

    @Parameter(title: "Weekday")
    public var weekday: Int

    @Parameter(title: "Skip current occurrence")
    public var skipCurrentOccurrence: Bool

    public init(weekday: Int, skipCurrentOccurrence: Bool = true) {
        self.weekday = weekday
        self.skipCurrentOccurrence = skipCurrentOccurrence
    }

    public init() {
        self.weekday = 1
        self.skipCurrentOccurrence = false
    }

    public func perform() async throws -> some IntentResult {
        await SmartWakeAlarmScheduler.rearmFallback(for: weekday, skipCurrentOccurrence: skipCurrentOccurrence)
        return .result()
    }
}
#endif
